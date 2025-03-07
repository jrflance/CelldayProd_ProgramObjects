--liquibase formatted sql

--changeset MHoward:0D5557 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
 /*=============================================
             : 
      Author : John Rose
 Create Date : 2015-05-21
             : 
 Description : Based on [Report].[P_Report_Ultra_Mobile_Weekly_Details] with different specs.
             : 
  JR20150521 : Matched KP spec's regarding SIM, MOBILE_NUMBER, ULTRAMA, and DEALERCODE columns.
  JR20150610 : '--'s replaced by ''s and final output enclosed in double quotes.
  JR20150729 : Added switch to display Product_ID's on demand.
  JR20160406 : Changed @six- & @ten- Percent variables to @bottom- & @top- Percent to accommodate
             : rate changes like those of 2016-04-01 (@bottomPercent = .040 & @topPercent = .085).
  JR20160414 : Corrected all uses of the rate change parameters.
  JR20160420 : Added Univision products: categories 534 (Activation) & 539 (Top Up). Because of rate 
             : changes, removed order collection blocks: IF @EveningEnd <= '2015-04-01' 
  JR20161029 : Now pulling in VidaExpress transactions
  CH20170119 : Use of new table instead of logs.servicelog Inc-66986
  JR20170228 : Added a @switchPercent parameter to tweak the bottom vs. top percentage rates.
  JL20170602 : Added UltraFlex logic
  JL20170814 : Added Ultra Multi-Month Plans
  BS20190411 : Updated SPIFF payout per Ultra April 2019 SPIFF Letter.
  BS20190419 : Added more hard coding to report correct 3 month plan "Pay Quicker" amount. 
  JR20190507 : Adjusted for new percentages and Spiff's. Replaced string searches with product ID's.
  MR20200929 : Added the activation refund order types 74 and 75 to the activation section.
  MH20210830 : Changed PayQuickerAmt from hard-coded amount by Product_ID to actual Spiff paid.
 KMH20211117 : Added Provider Trans ID
			 : Changed discounts for approved vs nonapproved dealers, MAs by creating table dbo.CarrierDealerDiscount
			 : instead of the hardcoding in the report
             : Removed API log collection as it stopped being used ~2018 after convo with Zaher
			 : Removed VidaPayExpress logic since no longer used
			 : Decision made to default @prodIDs = 1 for display; kept logic in case we need to disable
			 :
 KMH20220119 : Added @ReportingPlatform parameter and case statement for @EveningEnd so SP can be utilized in both SSRS 
			 : and CRM with different end dates according to platform it is running on without duplicating SP. 
			 : Added @SessionID parameter for CRM and @ReportingParameter for CRM error if SessionID <> 2
			 :
 MH20240215	 : Removed ParentItemID to accomidate activation fee
			 :
       Usage : EXEC [Report].[P_Report_Ultra_Mobile_Next_Gen_Weekly_Details] '2019-05-01', '2019-05-10', 1
             : EXEC [Report].[P_Report_Ultra_Mobile_Next_Gen_Weekly_Details] null, null, 0
             : 
		 Job : Step 6 of ETL - FTP - File Transfer.HourlyBetween01:00&08:00 (I believe)
   Reporting : SSRS Jobs01 and DB03, Ultra Mobile Next Gen Weekly Details
 =============================================*/ 
CREATE OR ALTER PROCEDURE [Report].[P_Report_Ultra_Mobile_Next_Gen_Weekly_Details]
(
    @StartDate         DATETIME = NULL,
    @EndDate           DATETIME = NULL,
    @prodIDs           BIT      = 1, -- 0 = do not display product ID's; 1 = display product ID's: [Product1]
    @SessionID         INT      = NULL,
    @ReportingPlatform SMALLINT = 0 --KMH20220119 0 SSRS, 1 CRM
)
AS

BEGIN TRY
    SET NOCOUNT ON;

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF(
          @ReportingPlatform = 1
          AND ISNULL(@SessionID, 0) <> 2
      ) --KMH20220119 
        RAISERROR('This report is highly restricted. Please see your T-Cetra representative if you wish to request access.', 12, 1);

    IF(
          @StartDate IS NULL
          OR @EndDate IS NULL
      )
    BEGIN
        DECLARE @backOffDays INT = CASE DATEPART(WEEKDAY, GETDATE())
                                       WHEN 1
                                           THEN 0
                                       WHEN 2
                                           THEN -1
                                       WHEN 3
                                           THEN -2
                                       WHEN 4
                                           THEN -3
                                       WHEN 5
                                           THEN -4
                                       WHEN 6
                                           THEN -5
                                       WHEN 7
                                           THEN -6
                                   END;

        SET @EndDate = DATEADD(DAY, @backOffDays, GETDATE());
        SET @StartDate = DATEADD(DAY, -6, @EndDate);
    END;

    DECLARE
        @MorningStart DATE = CAST(@StartDate AS DATE),
        @EveningEnd   DATE = CASE
                                 WHEN @ReportingPlatform = 1 --KMH20220119
                                     THEN CAST(@EndDate AS DATE)
                                 ELSE CAST(DATEADD(DAY, 1, @EndDate) AS DATE)
                             END;

    --CAST(DATEADD(DAY, 1, @EndDate) AS DATE);
    IF(@MorningStart < DATEADD(DAY, -365, GETDATE()))
    BEGIN
        SELECT
            '            Report Restricted to 1 year        ' AS [Error]
        UNION
        SELECT
            '      Please re-enter your dates and try again!' AS [Error]
        RETURN
    END;

    IF(@MorningStart > @EveningEnd)
    BEGIN
        SELECT
            'Start date can not be later than the end date,' AS [Error]
        UNION
        SELECT
            '      please re-enter your dates!' AS [Error];
        RETURN
    END;

    IF OBJECT_ID('tempdb..#tmpOrder_NoActivation') IS NOT NULL
    BEGIN
        DROP TABLE #tmpOrder_NoActivation;
    END;

    CREATE TABLE #tmpOrder_NoActivation
    (
        Order_No   INT,
        ID         INT,
        SKU        NVARCHAR(100),
        Product_ID INT,
        TransAmt   DECIMAL(9, 2)
    );

    -- Begin collecting Ultra activation orders -------------------------------------------------------------------------
    BEGIN
        INSERT INTO #tmpOrder_NoActivation
        (
            Order_No,
            ID,
            SKU,
            Product_ID,
            TransAmt
        )
                    (SELECT
                         od.Order_No,
                         os.ID,
                         os.SKU,
                         pd.Product_ID,
                         CASE
                             WHEN os.Fee IS NULL
                                 THEN CASE
                                          WHEN os.Price = pd.Base_Price + 1
                                              THEN CAST((os.Price - 1) AS DECIMAL(8, 2))
                                          WHEN os.Price = pd.Base_Price + 3
                                              THEN CAST((os.Price - 3) AS DECIMAL(8, 2))
                                          ELSE CAST(os.Price AS DECIMAL(8, 2))
                                      END
                             ELSE CAST(os.Price AS DECIMAL(8, 2))
                         END AS [TransAmt]
                     FROM
                         dbo.Order_No od WITH(NOLOCK)
                     JOIN dbo.Orders os WITH(NOLOCK)
                         ON os.Order_No = od.Order_No
                     --AND os.ParentItemID = 0	--MH20240215 (removed)
                     JOIN dbo.Products pd WITH(NOLOCK, INDEX(IX_Products_Product_Type))
                         ON os.Product_ID = pd.Product_ID
                            --AND ISNULL(pd.Product_Type,0) IN (3,4)	--MH20240215 (removed)
                            AND ISNULL(pd.Product_Type, 0) = 3 --MH20240215
                     JOIN Products.tblProductCarrierMapping cm WITH(NOLOCK)
                         ON pd.Product_ID = cm.ProductId
                     JOIN dbo.Carrier_ID ca WITH(NOLOCK)
                         ON cm.CarrierId = ca.ID
                            AND ISNULL(ca.ParentCompanyId, 0) = 2
                     WHERE
                         od.Process = 1
                         AND od.Filled = 1
                         AND od.Void = 0
                         AND od.OrderType_ID IN (
                                                    22, 23, 74, 75
                                                ) --refund types MR20200929
                         AND ISNUMERIC(os.SKU) = 1
                         AND LEN(os.SKU) = 10
                         AND od.DateFilled >= @MorningStart
                         AND od.DateFilled < @EveningEnd)
        OPTION(OPTIMIZE FOR(@MorningStart = '2015-05-01', @EveningEnd = '2015-05-10'));
    END;

    -- End collecting Ultra activation orders ---------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#tmpOrder_NoAirtime') IS NOT NULL
    BEGIN
        DROP TABLE #tmpOrder_NoAirtime;
    END;

    CREATE TABLE #tmpOrder_NoAirtime
    (
        Order_No   INT,
        ID         INT,
        SKU        NVARCHAR(100),
        Product_ID INT,
        TransAmt   DECIMAL(9, 2)
    );

    -- Begin collecting Ultra purchases ---------------------------------------------------------------------------
    BEGIN
        INSERT INTO #tmpOrder_NoAirtime
        (
            Order_No,
            ID,
            SKU,
            Product_ID,
            TransAmt
        )
                    (SELECT
                         od.Order_No,
                         os.ID,
                         os.SKU,
                         pd.Product_ID,
                         CASE
                             WHEN os.Fee IS NULL
                                 THEN CASE
                                          WHEN os.Product_ID IN (
                                                                    1916, 3970
                                                                ) -- Ultra RTR $11-$100, Ultra Wallet $3-$10
                                              THEN CAST((os.Price - 1) AS DECIMAL(8, 2))
                                          WHEN os.Price = pd.Base_Price + 1
                                              THEN CAST((os.Price - 1) AS DECIMAL(8, 2))
                                          WHEN os.Price = pd.Base_Price + 3
                                              THEN CAST((os.Price - 3) AS DECIMAL(8, 2))
                                          ELSE CAST(os.Price AS DECIMAL(8, 2))
                                      END
                             ELSE CAST(os.Price AS DECIMAL(8, 2))
                         END AS [TransAmt]
                     FROM
                         dbo.Order_No od WITH(NOLOCK)
                     JOIN dbo.Orders os WITH(NOLOCK)
                         ON os.Order_No = od.Order_No
                     JOIN dbo.Products pd WITH(NOLOCK, INDEX([IX_Products_Product_Type]))
                         ON os.Product_ID = pd.Product_ID
                            AND ISNULL(pd.Product_Type, 0) IN (
                                                                  0, 1, 2
                                                              )
                     JOIN Products.tblProductCarrierMapping cm WITH(NOLOCK)
                         ON pd.Product_ID = cm.ProductId
                     JOIN dbo.Carrier_ID ca WITH(NOLOCK)
                         ON cm.CarrierId = ca.ID
                            AND ISNULL(ca.ParentCompanyId, 0) = 2
                     WHERE
                         od.Process = 1
                         AND od.Filled = 1
                         AND od.Void = 0
                         AND od.OrderType_ID IN (
                                                    1, 9
                                                )
                         AND ISNUMERIC(os.SKU) = 1
                         AND LEN(os.SKU) = 10
                         AND od.DateFilled >= @MorningStart
                         AND od.DateFilled < @EveningEnd)
        OPTION(OPTIMIZE FOR(@MorningStart = '2015-05-01', @EveningEnd = '2015-05-10'));
    END;

    -- End collecting Ultra purchases ---------------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#tmpOrder_Flex') IS NOT NULL
    BEGIN
        DROP TABLE #tmpOrder_Flex;
    END;

    CREATE TABLE #tmpOrder_Flex
    (
        Order_no   INT,
        id         INT,
        SKU        NVARCHAR(100),
        Product_ID INT,
        TransAmt   DECIMAL(9, 2)
    );

    -- Begin collecting Ultra Flex purchases ---------------------------------------------------------------------------
    BEGIN
        INSERT INTO #tmpOrder_Flex
        (
            Order_no,
            id,
            SKU,
            Product_ID,
            TransAmt
        )
                    (SELECT
                         od.Order_No,
                         os.ID,
                         ISNULL(os.SKU, '') AS [SKU],
                         pd.Product_ID,
                         os.Price AS [TransAmt]
                     FROM
                         dbo.Order_No od
                     JOIN dbo.Orders os
                         ON os.Order_No = od.Order_No
                     JOIN dbo.Products pd WITH(INDEX([IX_Products_Product_Type]))
                         ON os.Product_ID = pd.Product_ID
                            AND ISNULL(pd.Product_Type, 0) IN (
                                                                  0, 1, 2
                                                              )
                     JOIN dbo.Product_Category pc
                         ON pc.Product_ID = pd.Product_ID
                            AND pc.Category_ID IN (
                                                      671
                                                  )
                     JOIN Products.tblProductCarrierMapping pcm
                         ON pd.Product_ID = pcm.ProductId
                     JOIN dbo.Carrier_ID c
                         ON pcm.CarrierId = c.ID
                            AND ISNULL(c.ParentCompanyId, 0) = 2
                     WHERE
                         od.DateFilled >= @MorningStart
                         AND od.DateFilled < @EveningEnd
                         AND od.Process = 1
                         AND od.Filled = 1
                         AND od.Void = 0
                         AND od.OrderType_ID IN (
                                                    1, 9
                                                ))
        OPTION(OPTIMIZE FOR(@MorningStart = '2015-05-01', @EveningEnd = '2015-05-10'));
    END;

    -- End collecting Ultra Flex purchases ---------------------------------------------------------------------------
    DECLARE @invoiceNumber VARCHAR(40)
        = SUBSTRING(CAST(CONVERT(VARCHAR(40), GETDATE(), 20) AS VARCHAR(40)), 9, LEN(CAST(CONVERT(VARCHAR(40), GETDATE(), 20) AS VARCHAR(40))))
          + SUBSTRING(CAST(DATEPART(YEAR, GETDATE()) AS VARCHAR(4)), 3, 2) + RIGHT('00' + CAST(DATEPART(MONTH, GETDATE()) AS VARCHAR(2)), 2)
    /* Derived @invoiceNumber is yy hh mm ss dd mm, so a date/time of
       '2015-04-15 08:24:329' becomes '15 08:24:291504'. The spaces and
       colons are REPLACE'd by '' in the query. This ensures a unique 
       @invoiceNumber value (until the year 3015).*/
    ;

    WITH CTE
    AS
    (
        -- Ultra Activations --------------------------------------------------------------
        SELECT
            os.SKU AS [REFERENCE_ID], --KMH20211117              
            REPLACE(REPLACE(@invoiceNumber, ' ', ''), ':', '') AS [InvoiceNumber],
            CAST(CAST(@EveningEnd AS DATE) AS VARCHAR(20)) + ' 0:00' AS [InvoiceDate],
            CAST(CAST(DATEADD(DAY, 7, @EveningEnd) AS DATE) AS VARCHAR(20)) + ' 0:00' AS [SettlementDate],
            CASE
                WHEN CHARINDEX('F', oo.AddonsValue) = LEN(oo.AddonsValue)
                    THEN SUBSTRING(oo.AddonsValue, 0, LEN(oo.AddonsValue))
                ELSE LTRIM(RTRIM(oo.AddonsValue))
            END AS [SIM],
            CASE
                WHEN ISNULL(oi.AddonsValue, '0') <> '0'
                    THEN oi.AddonsValue
                ELSE CASE
                         WHEN ISNULL(ot.AddonsValue, '0') <> '0'
                             THEN ot.AddonsValue
                         ELSE '-n/a-'
                     END
            END AS [MobileNumber],
            os.ID AS [ProviderTransactionID], --KMH20211117
            od.Order_No AS [TransID],
            tn.TransAmt AS [TransAmt],
            CASE
                WHEN ISNULL(dc.AccountID, 0) = 0
                    THEN cdd.Dealer_NonapprovedDiscount
                ELSE cdd.Dealer_ApprovedDiscount
            END AS [PercentageRate], --KMH20211117
            CAST(((-1 * cdd.Tcetra_Discount) * tn.TransAmt) AS DECIMAL(8, 2)) AS [TCetraAmt], --KMH20211117
            cdd.Tcetra_Discount AS [TCetraFeePercentage], --KMH20211117
            CASE
                WHEN ISNULL(dc.AccountID, 0) = 0
                    THEN CAST((tn.TransAmt * cdd.Dealer_NonapprovedDiscount) AS DECIMAL(8, 2))
                ELSE CAST((tn.TransAmt * cdd.Dealer_ApprovedDiscount) AS DECIMAL(8, 2))
            END AS [DiscountAmt], --KMH20211117
            os.Fee AS [RecoveryAmt],
            tn.Product_ID AS [Product_ID],
            CONVERT(CHAR(10), od.DateFilled, 101) + ' ' + CONVERT(CHAR(5), od.DateFilled, 108) AS [HostTimeStamp1],
            'Y' AS [PayQuickerFlag], -- PayQuickerFlag = 'Y' for activations.
            CAST(oe.Price AS DECIMAL(8, 2)) AS [PayQuicker Amt], -- Spiff for activations.
            os.Name AS [ProductName1],
            IIF(@prodIDs = 1, CAST(os.Product_ID AS VARCHAR(10)), '') AS [Product1],
            IIF(@prodIDs = 1, os.Name, '') AS [MappedProduct1],
            '' AS [FeeProduct],
            '' AS [SupplierAcc1],
            CAST(os.Price AS DECIMAL(8, 2)) AS [Value1],
            'DEB' AS [TXNType1],
            IIF(ISNULL(dc.AccountID, 0) = 0, '-n/a-', ISNULL(ad.Account_Name, '-n/a-')) AS [UltraMA],
            od.Account_ID AS [TerminalID1],
            CASE
                WHEN ISNULL(dl.DealerCode, 'UMTEMP') = 'UMTEMP'
                    THEN pk.VendorSku
                ELSE LTRIM(RTRIM(dl.DealerCode))
            END AS [DealerCode],
            LTRIM(RTRIM(ac.Account_Name)) AS [RetailerName],
            LTRIM(RTRIM(cu.Address1)) AS [Address1],
            LTRIM(RTRIM(ISNULL(cu.Address2, ''))) AS [Address2],
            LTRIM(RTRIM(cu.City)) AS [Address3],
            LTRIM(RTRIM(cu.State)) AS [Address4],
            LTRIM(RTRIM(cu.Zip)) AS [PostCode]
        FROM
            #tmpOrder_NoActivation tn WITH(NOLOCK)
        JOIN dbo.Order_No od WITH(NOLOCK)
            ON tn.Order_No = od.Order_No
        JOIN dbo.Orders os WITH(NOLOCK)
            ON tn.ID = os.ID
               AND tn.Product_ID = os.Product_ID
        JOIN dbo.Products pd WITH(NOLOCK)
            ON os.Product_ID = pd.Product_ID ---FIX
        LEFT JOIN dbo.tblOrderItemAddons oo WITH(NOLOCK)
            ON os.ID = oo.OrderID
               AND oo.AddonsID = 22 -----------FIX

        --LEFT JOIN dbo.Orders oe WITH (NOLOCK) ON oe.Order_No      = od.Order_No	--MH20240215 (replace with join below)
        --                                     AND oe.ParentItemID <> 0
        LEFT JOIN
        ( --MH20240215
            SELECT
                o.ID,
                o.Order_No,
                o.Price
            FROM
                dbo.Orders o WITH(NOLOCK)
            JOIN dbo.Products AS p
                ON o.Product_ID = p.Product_ID
                   AND p.Product_Type = 4
        ) oe
            ON oe.Order_No = od.Order_No
        LEFT JOIN dbo.tblOrderItemAddons oi WITH(NOLOCK)
            ON oe.ID = oi.OrderID
               AND
               (
                   oi.AddonsID IN (
                                      8, 23
                                  )
                   AND oi.AddonsID NOT IN (
                                              27
                                          ) ---------FIX
               )
        LEFT JOIN dbo.tblOrderItemAddons ot WITH(NOLOCK)
            ON oe.ID = ot.OrderID
               AND ot.AddonsID IN (
                                      27
                                  ) ---------FIX
        JOIN dbo.Customers cu WITH(NOLOCK)
            ON cu.Customer_ID = od.Customer_ID
        JOIN dbo.Account ac WITH(NOLOCK)
            ON od.Account_ID = ac.Account_ID
        LEFT JOIN CarrierSetup.tblAccountDealerCode dl WITH(NOLOCK)
            ON dl.AccountID = ac.ParentAccount_Account_ID
        LEFT JOIN dbo.Phone_Active_Kit pk WITH(NOLOCK)
            ON pk.Order_No = od.Order_No
        LEFT JOIN CarrierSetup.tblAccountDealerCode dc WITH(NOLOCK)
            ON dc.AccountID = dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy)
               AND dc.DealerCode NOT IN (
                                            'UMTEMP', '2'
                                        ) --KMH20211117
        LEFT JOIN dbo.Account ad WITH(NOLOCK)
            ON dc.AccountID = ad.Account_ID
        CROSS JOIN dbo.CarrierDealerDiscount cdd --KMH20211117
        WHERE
            cdd.ParentCompany_ID = 2 --Ultra Mobile
        UNION ALL -- Ultra Purchases --------------------------------------------------------------
        SELECT
            os.SKU AS [REFERENCE_ID], --KMH20211117
            REPLACE(REPLACE(@invoiceNumber, ' ', ''), ':', '') AS [InvoiceNumber],
            CAST(CAST(@EveningEnd AS DATE) AS VARCHAR(20)) + ' 0:00' AS [InvoiceDate],
            CAST(CAST(DATEADD(DAY, 7, @EveningEnd) AS DATE) AS VARCHAR(20)) + ' 0:00' AS [SettlementDate],
            '' AS [SIM],
            CASE
                WHEN ISNULL(oi.AddonsValue, '0') <> '0'
                    THEN oi.AddonsValue
                ELSE
                    CASE
                        WHEN PATINDEX('%enter phone number:%', CAST(os.Addons AS VARCHAR(200))) > 0
                            THEN SUBSTRING(
                                              CAST(os.Addons AS VARCHAR(200)),
                                              PATINDEX('%enter phone number:%', CAST(os.Addons AS VARCHAR(200))) + 19, 10
                                          )
                        ELSE
                            CASE
                                WHEN PATINDEX('%phone[_]number:%', CAST(os.Addons AS VARCHAR(200))) > 0
                                    THEN SUBSTRING(
                                                      CAST(os.Addons AS VARCHAR(200)),
                                                      PATINDEX('%phone[_]number:%', CAST(os.Addons AS VARCHAR(200))) + 13, 10
                                                  )
                                ELSE
                                    CASE
                                        WHEN PATINDEX('%phone number: %', CAST(os.Addons AS VARCHAR(200))) > 0
                                            THEN SUBSTRING(
                                                              CAST(os.Addons AS VARCHAR(200)),
                                                              PATINDEX('%phone number: %', CAST(os.Addons AS VARCHAR(200))) + 14, 10
                                                          )
                                        ELSE
                                            CASE
                                                WHEN PATINDEX('%phone number:%', CAST(os.Addons AS VARCHAR(200))) > 0
                                                    THEN SUBSTRING(
                                                                      CAST(os.Addons AS VARCHAR(200)),
                                                                      PATINDEX('%phone number:%', CAST(os.Addons AS VARCHAR(200))) + 13, 10
                                                                  )
                                                ELSE ''
                                            END
                                    END
                            END
                    END
            END AS [MobileNumber],
            os.ID AS [ProviderTransactionID], --KMH20211117
            od.Order_No AS [TransID],
            tn.TransAmt AS [TransAmt],
            CASE
                WHEN ISNULL(dc.AccountID, 0) = 0
                    THEN cdd.Dealer_NonapprovedDiscount
                ELSE cdd.Dealer_ApprovedDiscount
            END AS [PercentageRate], --KMH20211117
            CAST(((-1 * cdd.Tcetra_Discount) * tn.TransAmt) AS DECIMAL(8, 2)) AS [TCetraAmt], --KMH20211117
            cdd.Tcetra_Discount AS [TCetraFeePercentage], --KMH20211117
            CASE
                WHEN tn.TransAmt > 0
                    THEN CASE
                             WHEN ISNULL(dc.AccountID, 0) = 0
                                 THEN CAST((tn.TransAmt * cdd.Dealer_NonapprovedDiscount) AS DECIMAL(8, 2))
                             ELSE CAST((tn.TransAmt * cdd.Dealer_ApprovedDiscount) AS DECIMAL(8, 2))
                         END
                ELSE CAST(0.00 AS DECIMAL(8, 3))
            END AS [DiscountAmt], --KMH20211117
            os.Fee AS [RecoveryAmt],
            tn.Product_ID AS [Product_ID],
            CONVERT(CHAR(10), od.DateFilled, 101) + ' ' + CONVERT(CHAR(5), od.DateFilled, 108) AS [HostTimeStamp1],
            'N' AS [PayQuickerFlag],
            CAST(ISNULL(oe.Price, 0.00) AS DECIMAL(8, 2)) AS [PayQuicker Amt],
            os.Name AS [ProductName1],
            IIF(@prodIDs = 1, CAST(os.Product_ID AS VARCHAR(10)), '') AS [Product1],
            IIF(@prodIDs = 1, os.Name, '') AS [MappedProduct1],
            '' AS [FeeProduct],
            '' AS [SupplierAcc1],
            CAST(os.Price AS DECIMAL(8, 2)) AS [Value1],
            'DEB' AS [TXNType1],
            IIF(ISNULL(dc.AccountID, 0) = 0, '-n/a-', ISNULL(ad.Account_Name, '-n/a-')) AS [UltraMA],
            od.Account_ID AS [TerminalID1],
            LTRIM(RTRIM(ISNULL(dl.DealerCode, 'UMTEMP'))) AS [DealerCode],
            LTRIM(RTRIM(ac.Account_Name)) AS [RetailerName],
            LTRIM(RTRIM(cu.Address1)) AS [Address1],
            LTRIM(RTRIM(ISNULL(cu.Address2, ''))) AS [Address2],
            LTRIM(RTRIM(cu.City)) AS [Address3],
            LTRIM(RTRIM(cu.State)) AS [Address4],
            LTRIM(RTRIM(cu.Zip)) AS [PostCode]
        FROM
            #tmpOrder_NoAirtime tn
        JOIN dbo.Orders os WITH(NOLOCK)
            ON tn.ID = os.ID
               AND tn.Product_ID = os.Product_ID
        JOIN dbo.Order_No od WITH(NOLOCK)
            ON tn.Order_No = od.Order_No
        --LEFT JOIN dbo.Orders oe WITH (NOLOCK) ON oe.Order_No      = od.Order_No	--MH20240215 (replace with join below)
        --                                     AND oe.ParentItemID <> 0
        LEFT JOIN
        ( --MH20240215
            SELECT
                o.Order_No,
                o.Price
            FROM
                dbo.Orders o WITH(NOLOCK)
            JOIN dbo.Products AS p
                ON o.Product_ID = p.Product_ID
                   AND p.Product_Type = 4
        ) oe
            ON oe.Order_No = od.Order_No
        LEFT JOIN dbo.tblOrderItemAddons oi WITH(NOLOCK)
            ON os.ID = oi.OrderID
               AND oi.AddonsID IN (
                                      8, 23
                                  ) -----FIX
        JOIN dbo.Customers cu WITH(NOLOCK)
            ON cu.Customer_ID = od.Customer_ID
        JOIN dbo.Account ac WITH(NOLOCK)
            ON od.Account_ID = ac.Account_ID
        LEFT JOIN CarrierSetup.tblAccountDealerCode dl WITH(NOLOCK)
            ON dl.AccountID = ac.ParentAccount_Account_ID
        LEFT JOIN CarrierSetup.tblAccountDealerCode dc WITH(NOLOCK)
            ON dc.AccountID = dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy)
               AND dc.DealerCode NOT IN (
                                            'UMTEMP', '2'
                                        ) --KMH20211117
        --AND dc.AccountID IN (21921,31696,42428,76063,130818)
        LEFT JOIN dbo.Account ad WITH(NOLOCK)
            ON dc.AccountID = ad.Account_ID
        CROSS JOIN dbo.CarrierDealerDiscount AS cdd --KMH20211117
        WHERE
            cdd.ParentCompany_ID = 2 --Ultra Mobile
    ),
    CTE2
    AS
    (
        -- Ultra Flex Purchases --------------------------------------------------------------
        SELECT
            ISNULL(os.SKU, '') AS [REFERENCE_ID], --KMH20211117
            REPLACE(REPLACE(@invoiceNumber, ' ', ''), ':', '') AS [InvoiceNumber],
            CAST(CAST(@EveningEnd AS DATE) AS VARCHAR(20)) + ' 0:00' AS [InvoiceDate],
            CAST(CAST(DATEADD(DAY, 7, @EveningEnd) AS DATE) AS VARCHAR(20)) + ' 0:00' AS [SettlementDate],
            '' AS [SIM],
            CASE
                WHEN ISNULL(oi.AddonsValue, '0') <> '0'
                    THEN oi.AddonsValue
                ELSE
                    CASE
                        WHEN PATINDEX('%enter phone number:%', CAST(os.Addons AS VARCHAR(200))) > 0
                            THEN SUBSTRING(
                                              CAST(os.Addons AS VARCHAR(200)),
                                              PATINDEX('%enter phone number:%', CAST(os.Addons AS VARCHAR(200))) + 19, 10
                                          )
                        ELSE
                            CASE
                                WHEN PATINDEX('%phone[_]number:%', CAST(os.Addons AS VARCHAR(200))) > 0
                                    THEN SUBSTRING(
                                                      CAST(os.Addons AS VARCHAR(200)),
                                                      PATINDEX('%phone[_]number:%', CAST(os.Addons AS VARCHAR(200))) + 13, 10
                                                  )
                                ELSE
                                    CASE
                                        WHEN PATINDEX('%phone number: %', CAST(os.Addons AS VARCHAR(200))) > 0
                                            THEN SUBSTRING(
                                                              CAST(os.Addons AS VARCHAR(200)),
                                                              PATINDEX('%phone number: %', CAST(os.Addons AS VARCHAR(200))) + 14, 10
                                                          )
                                        ELSE
                                            CASE
                                                WHEN PATINDEX('%phone number:%', CAST(os.Addons AS VARCHAR(200))) > 0
                                                    THEN SUBSTRING(
                                                                      CAST(os.Addons AS VARCHAR(200)),
                                                                      PATINDEX('%phone number:%', CAST(os.Addons AS VARCHAR(200))) + 13, 10
                                                                  )
                                                ELSE ''
                                            END
                                    END
                            END
                    END
            END AS [MobileNumber],
            os.id AS [ProviderTransactionID], --KMH20211117
            od.Order_no AS [TransID],
            tn.TransAmt AS [TransAmt],
            CASE
                WHEN tn.TransAmt > 0
                    THEN CASE
                             WHEN ISNULL(dc.AccountID, 0) = 0
                                 THEN cdd.Dealer_NonapprovedDiscount
                             ELSE cdd.Dealer_ApprovedDiscount
                         END
            END AS [PercentageRate], --KMH20211117
            CAST(((-1 * cdd.Tcetra_Discount) * tn.TransAmt) AS DECIMAL(8, 2)) AS [TCetraAmt], --KMH20211117
            cdd.Tcetra_Discount AS [TCetraFeePercentage], --KMH20211117
            CASE
                WHEN tn.TransAmt > 0
                    THEN CASE
                             WHEN ISNULL(dc.AccountID, 0) = 0
                                 THEN CAST((tn.TransAmt * cdd.Dealer_NonapprovedDiscount) AS DECIMAL(8, 2))
                             ELSE CAST((tn.TransAmt * cdd.Dealer_ApprovedDiscount) AS DECIMAL(8, 2))
                         END
                ELSE CAST(0.00 AS DECIMAL(8, 3))
            END AS [DiscountAmt], --KMH20211117
            os.Fee AS [RecoveryAmt],
            tn.Product_ID AS [Product_ID],
            CONVERT(CHAR(10), od.DateFilled, 101) + ' ' + CONVERT(CHAR(5), od.DateFilled, 108) AS [HostTimeStamp1],
            'N' AS [PayQuickerFlag],
            CAST(ISNULL(oe.Price, 0.00) AS DECIMAL(8, 2)) AS [PayQuicker Amt],
            os.Name AS [ProductName1],
            IIF(@prodIDs = 1, CAST(os.Product_ID AS VARCHAR(10)), '') AS [Product1],
            IIF(@prodIDs = 1, os.Name, '') AS [MappedProduct1],
            '' AS [FeeProduct],
            '' AS [SupplierAcc1],
            CAST(os.Price AS DECIMAL(8, 2)) AS [Value1],
            'DEB' AS [TXNType1],
            IIF(ISNULL(dc.AccountID, 0) = 0, '-n/a-', ISNULL(ad.Account_Name, '-n/a-')) AS [UltraMA],
            od.Account_ID AS [TerminalID1],
            LTRIM(RTRIM(ISNULL(dl.DealerCode, 'UMTEMP'))) AS [DealerCode],
            LTRIM(RTRIM(ac.Account_Name)) AS [RetailerName],
            LTRIM(RTRIM(cu.Address1)) AS [Address1],
            LTRIM(RTRIM(ISNULL(cu.Address2, ''))) AS [Address2],
            LTRIM(RTRIM(cu.City)) AS [Address3],
            LTRIM(RTRIM(cu.State)) AS [Address4],
            LTRIM(RTRIM(cu.Zip)) AS [PostCode]
        FROM
            #tmpOrder_Flex tn
        JOIN dbo.Orders os WITH(NOLOCK)
            ON tn.id = os.id
               AND tn.Product_ID = os.Product_ID
        JOIN dbo.Order_No od WITH(NOLOCK)
            ON tn.Order_no = od.Order_no
        --LEFT JOIN dbo.Orders oe WITH (NOLOCK) ON oe.Order_No      = od.Order_No	--MH20240215 (replace with join below)
        --                                     AND oe.ParentItemID <> 0
        LEFT JOIN
        ( --MH20240215
            SELECT
                o.Order_No,
                o.Price
            FROM
                dbo.Orders o WITH(NOLOCK)
            JOIN dbo.Products AS p
                ON o.Product_ID = p.Product_ID
                   AND p.Product_Type = 4
        ) oe
            ON oe.Order_no = od.Order_no
        LEFT JOIN dbo.tblOrderItemAddons oi WITH(NOLOCK)
            ON os.id = oi.OrderID
               AND oi.AddonsID IN (
                                      8, 23
                                  ) -----FIX
        JOIN dbo.Customers cu WITH(NOLOCK)
            ON cu.Customer_ID = od.Customer_ID
        JOIN dbo.Account ac WITH(NOLOCK)
            ON od.Account_ID = ac.Account_ID
        LEFT JOIN CarrierSetup.tblAccountDealerCode dl WITH(NOLOCK)
            ON ac.ParentAccount_Account_ID = dl.AccountID
        LEFT JOIN CarrierSetup.tblAccountDealerCode dc WITH(NOLOCK)
            ON dc.AccountID = dbo.fn_GetTopParent_NotTcetra_h(ac.Hierarchy)
               AND dc.DealerCode NOT IN (
                                            'UMTEMP', '2'
                                        ) --KMH20211117
        --AND dc.AccountID IN (21921,31696,42428,76063,130818)
        LEFT JOIN dbo.Account ad WITH(NOLOCK)
            ON dc.AccountID = ad.Account_ID
        CROSS JOIN dbo.CarrierDealerDiscount AS cdd --KMH20211117
        WHERE
            cdd.ParentCompany_ID = 2 --Ultra Mobile
    )
    SELECT DISTINCT
        '"' + [InvoiceNumber] + '"' AS [InvoiceNumber],
        '"' + [InvoiceDate] + '"' AS [InvoiceDate],
        '"' + [SettlementDate] + '"' AS [SettlementDate],
        '"' + [SIM] + '"' AS [SIM],
        '"' + [MobileNumber] + '"' AS [MobileNumber],
        '"' + CAST([ProviderTransactionID] AS VARCHAR(20)) + '"' AS [ProviderTransactionID], --KMH20211117
        '"' + CAST([TransID] AS VARCHAR(20)) + '"' AS [TransID],
        '"' + [REFERENCE_ID] + '"' AS [Reference_ID],
        '"' + CAST([TransAmt] AS VARCHAR(20)) + '"' AS [TransAmt],
        '"' + CAST(CAST((1 - [PercentageRate]) * 100 AS DECIMAL(8, 2)) AS VARCHAR(20)) + '%' + '"' AS [MarginPcnt],
        '"' + CAST(CAST(([TCetraFeePercentage] * 100) AS DECIMAL(8, 2)) AS VARCHAR(10)) + '%' + '"' AS [TCetraPcnt],
        '"' + CAST(CASE
                       WHEN [UltraMA] LIKE '%-n/a-%'
                           THEN CAST(CAST((cdd.MA_NonapprovedDiscount * 100) AS DECIMAL(8, 2)) AS VARCHAR(10)) + '%'
                       ELSE CAST(CAST((cdd.MA_ApprovedDiscount * 100) AS DECIMAL(8, 2)) AS VARCHAR(10)) + '%'
                   END AS VARCHAR(10)) + '"' AS [MAPcnt],
        '"' + [PayQuickerFlag] + '"' AS [PayQuickerFlag],
        '"' + CAST(CASE
                       WHEN [UltraMA] LIKE '%-n/a-%'
                           THEN CAST(((1 - cdd.Dealer_NonapprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((1 - cdd.Dealer_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END AS VARCHAR(20)) + '"' AS [UltraAmtNetofDiscount],
        '"' + CAST([TCetraAmt] AS VARCHAR(20)) + '"' AS [TCetraAmt],
        ----'"' + CASE WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
        ----           THEN CASE WHEN [Product_ID] IN (1918,8217,1919,1921,1922)
        ----                     THEN CAST(CAST(-5.00 AS DECIMAL(8,2)) AS VARCHAR(10))
        ----                     WHEN [Product_ID] IN (8399,9051,8400,8401,8402)
        ----                     THEN CAST(CAST(-15.00 AS DECIMAL(8,2)) AS VARCHAR(10))
        ----                     ELSE CAST('0.00' AS VARCHAR(10))
        ----                END
        ----           ELSE CAST('0.00' AS VARCHAR(10))
        ----      END
        ----    + '"'                                                        AS [PayQuickerAmt],
        '"' + CASE
                  WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419						--MH20210830
                      THEN CAST(ISNULL([PayQuicker Amt], 0) AS VARCHAR(10))
                  ELSE CAST('0.00' AS VARCHAR(10))
              END + '"' AS [PayQuickerAmt],
        '"' + CAST(CASE
                       WHEN [UltraMA] LIKE '%-n/a-%'
                           THEN CAST((cdd.MA_NonapprovedDiscount * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((-1 * cdd.MA_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END AS VARCHAR(20)) + '"' AS [MAAmt],

        --     Begin [UltraAmtBeforeRecovery] formula -----------------------------------------------------------------
        '"' + CAST(CASE
                       WHEN [UltraMA] NOT LIKE '%-n/a-%'
                           THEN CAST(((1 - cdd.Dealer_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((1 - cdd.Dealer_nonapprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END + [TCetraAmt] -- [TCetraAmt]
                   + CASE
                         WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
                             THEN CAST(ISNULL([PayQuicker Amt], 0) AS VARCHAR(10))
                         ELSE CAST('0.00' AS VARCHAR(10))
                     END -- [PayQuickerAmt]
                   + CASE
                         WHEN [UltraMA] NOT LIKE '%-n/a-%'
                             THEN CAST((-.01 * [TransAmt]) AS DECIMAL(8, 2))
                         ELSE CAST(0.00 AS DECIMAL(8, 2))
                     END AS VARCHAR(20)) + '"' AS [UltraAmtBeforeRecovery],
        --End [UltraAmtBeforeRecovery] formula -----------------------------------------------------------------
        '"' + CAST(CAST([RecoveryAmt] AS DECIMAL(8, 2)) AS VARCHAR(20)) + '"' AS [RecoveryAmt],

        --Begin [UltraAmt] formula -----------------------------------------------------------------
        '"' + CAST(CASE
                       WHEN [UltraMA] NOT LIKE '%-n/a-%'
                           THEN CAST(((1 - cdd.Dealer_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((1 - cdd.Dealer_nonapprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END + [TCetraAmt] -- [TCetraAmt]
                   +
        --CASE WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
        --     THEN CASE WHEN [Product_ID] IN (1918,8217,1919,1921,1922)
        --               THEN CAST(CAST(-5.00 AS DECIMAL(8,2)) AS VARCHAR(10))
        --               WHEN [Product_ID] IN (8399,9051,8400,8401,8402)
        --               THEN CAST(CAST(-15.00 AS DECIMAL(8,2)) AS VARCHAR(10))
        --               ELSE CAST('0.00' AS VARCHAR(10))
        --          END
        --     ELSE CAST('0.00' AS VARCHAR(10))
        --END -- [PayQuickerAmt]
        CASE
            WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
                THEN CAST(ISNULL([PayQuicker Amt], 0) AS VARCHAR(10))
            ELSE CAST('0.00' AS VARCHAR(10))
        END -- [PayQuickerAmt]
                   + CASE
                         WHEN [UltraMA] NOT LIKE '-n/a-'
                             THEN CAST((-.01 * [TransAmt]) AS DECIMAL(8, 2))
                         ELSE CAST(0.00 AS DECIMAL(8, 2))
                     END -- [MAAmt]
                   + CAST([RecoveryAmt] AS DECIMAL(8, 2)) -- [RecoveryAmt]
        AS VARCHAR(20)) + '"' AS [UltraAmt],
        --End [UltraAmt] formula -----------------------------------------------------------------
        '"' + CAST([HostTimeStamp1] AS VARCHAR(40)) + '"' AS [HostTimeStamp1],
        '"' + [ProductName1] + '"' AS [ProductName1],
        '"' + CAST([Product1] AS VARCHAR(40)) + '"' AS [Product1],
        '"' + [MappedProduct1] + '"' AS [MappedProduct1],
        '"' + [FeeProduct] + '"' AS [FeeProduct],
        '"' + [SupplierAcc1] + '"' AS [SupplierAcc1],
        '"' + CAST([TransAmt] AS VARCHAR(20)) + '"' AS [Value1],
        '"' + [TXNType1] + '"' AS [TXNType1],
        '"' + CAST([UltraMA] AS VARCHAR(30)) + '"' AS [UltraMA],
        '"' + CAST([TerminalID1] AS VARCHAR(20)) + '"' AS [TerminalID1],
        '"' + CAST([DealerCode] AS VARCHAR(20)) + '"' AS [DealerCode],
        '"' + [RetailerName] + '"' AS [RetailerName],
        '"' + [Address1] + '"' AS [Address1],
        '"' + [Address2] + '"' AS [Address2],
        '"' + [Address3] + '"' AS [Address3],
        '"' + [Address4] + '"' AS [Address4],
        '"' + CAST([PostCode] AS VARCHAR(20)) + '"' AS [PostCode]
    FROM
        CTE
    CROSS JOIN dbo.CarrierDealerDiscount AS cdd --KMH20211117
    WHERE
        cdd.ParentCompany_ID = 2 --Ultra Mobile
    UNION ALL
    SELECT DISTINCT
        '"' + [InvoiceNumber] + '"' AS [InvoiceNumber],
        '"' + [InvoiceDate] + '"' AS [InvoiceDate],
        '"' + [SettlementDate] + '"' AS [SettlementDate],
        '"' + [SIM] + '"' AS [SIM],
        '"' + [MobileNumber] + '"' AS [MobileNumber],
        '"' + CAST([ProviderTransactionID] AS VARCHAR(20)) + '"' AS [ProviderTransactionID], --KMH20211117
        '"' + CAST([TransID] AS VARCHAR(20)) + '"' AS [TransID],
        '"' + [REFERENCE_ID] + '"' AS [Reference_ID],
        '"' + CAST([TransAmt] AS VARCHAR(20)) + '"' AS [TransAmt],
        '"' + CAST(CAST((1 - [PercentageRate]) * 100 AS DECIMAL(8, 2)) AS VARCHAR(20)) + '%' + '"' AS [MarginPcnt],
        '"' + CAST(CAST(([TCetraFeePercentage] * 100) AS DECIMAL(8, 2)) AS VARCHAR(10)) + '%' + '"' AS [TCetraPcnt],
        '"' + CAST(CASE
                       WHEN [UltraMA] LIKE '%-n/a-%'
                           THEN CAST(CAST((cdd.MA_NonapprovedDiscount * 100) AS DECIMAL(8, 2)) AS VARCHAR(10)) + '%'
                       ELSE CAST(CAST((cdd.MA_ApprovedDiscount * 100) AS DECIMAL(8, 2)) AS VARCHAR(10)) + '%'
                   END AS VARCHAR(10)) + '"' AS [MAPcnt],
        '"' + [PayQuickerFlag] + '"' AS [PayQuickerFlag],
        '"' + CAST(CASE
                       WHEN [UltraMA] LIKE '%-n/a-%'
                           THEN CAST(((1 - cdd.Dealer_NonapprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((1 - cdd.Dealer_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END AS VARCHAR(20)) + '"' AS [UltraAmtNetofDiscount],
        '"' + CAST([TCetraAmt] AS VARCHAR(20)) + '"' AS [TCetraAmt],
        '"' + CASE
                  WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419						--MH20210830
                      THEN CAST(ISNULL([PayQuicker Amt], 0) AS VARCHAR(10))
                  ELSE CAST('0.00' AS VARCHAR(10))
              END + '"' AS [PayQuickerAmt],
        '"' + CAST(CASE
                       WHEN [UltraMA] LIKE '%-n/a-%'
                           THEN CAST((cdd.MA_NonapprovedDiscount * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((-1 * cdd.MA_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END AS VARCHAR(20)) + '"' AS [MAAmt],

        --Begin [UltraAmtBeforeRecovery] formula -----------------------------------------------------------------
        '"' + CAST(
        --'I''m the culprit'
        CASE
            WHEN [UltraMA] NOT LIKE '%-n/a-%'
                THEN CAST(((1 - cdd.Dealer_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
            ELSE CAST(((1 - cdd.Dealer_nonapprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
        END + [TCetraAmt] + CASE
                                WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
                                    THEN CAST(ISNULL([PayQuicker Amt], 0) AS VARCHAR(10))
                                ELSE CAST('0.00' AS VARCHAR(10))
                            END -- [PayQuickerAmt]
        +
        --CAST((-.01 * [TransAmt]) AS DECIMAL(8,2)) -- [MAAmt]
        CASE
            WHEN [UltraMA] NOT LIKE '%-n/a-%'
                THEN CAST((-.01 * [TransAmt]) AS DECIMAL(8, 2))
            ELSE CAST(0.00 AS DECIMAL(8, 2))
        END AS VARCHAR(20)) + '"' AS [UltraAmtBeforeRecovery],
        --End [UltraAmtBeforeRecovery] formula -----------------------------------------------------------------
        '"' + CAST(CAST([RecoveryAmt] AS DECIMAL(8, 2)) AS VARCHAR(20)) + '"' AS [RecoveryAmt],

        --Begin [UltraAmt] formula -----------------------------------------------------------------
        '"' + CAST(CASE
                       WHEN [UltraMA] NOT LIKE '%-n/a-%'
                           THEN CAST(((1 - cdd.Dealer_ApprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                       ELSE CAST(((1 - cdd.Dealer_nonapprovedDiscount) * [TransAmt]) AS DECIMAL(8, 2))
                   END -- [UltraAmtNetofDiscount]
                   + [TCetraAmt] -- [TCetraAmt]
                   +
        ----CASE WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
        ----     THEN CASE WHEN [Product_ID] IN (1918,8217,1919,1921,1922)
        ----               THEN CAST(CAST(-5.00 AS DECIMAL(8,2)) AS VARCHAR(10))
        ----               WHEN [Product_ID] IN (8399,9051,8400,8401,8402)
        ----               THEN CAST(CAST(-15.00 AS DECIMAL(8,2)) AS VARCHAR(10))
        ----               ELSE CAST('0.00' AS VARCHAR(10))
        ----          END
        ----     ELSE CAST('0.00' AS VARCHAR(10))
        ----END -- [PayQuickerAmt]
        CASE
            WHEN [PayQuickerFlag] = 'Y' --BS20190411--BS20190419					--MH20210830
                THEN CAST(ISNULL([PayQuicker Amt], 0) AS VARCHAR(10))
            ELSE CAST('0.00' AS VARCHAR(10))
        END -- [PayQuickerAmt]
                   +
        --CAST((-.01 * [TransAmt]) AS DECIMAL(8,2)) -- [MAAmt]
        CASE
            WHEN [UltraMA] NOT LIKE '-n/a-'
                THEN CAST((-.01 * [TransAmt]) AS DECIMAL(8, 2))
            ELSE CAST(0.00 AS DECIMAL(8, 2))
        END -- [MAAmt]
                   + CAST([RecoveryAmt] AS DECIMAL(8, 2)) AS VARCHAR(20)) + '"' AS [UltraAmt],
        --End [UltraAmt] formula -----------------------------------------------------------------
        '"' + CAST([HostTimeStamp1] AS VARCHAR(40)) + '"' AS [HostTimeStamp1],
        '"' + [ProductName1] + '"' AS [ProductName1],
        '"' + CAST([Product1] AS VARCHAR(40)) + '"' AS [Product1],
        '"' + [MappedProduct1] + '"' AS [MappedProduct1],
        '"' + [FeeProduct] + '"' AS [FeeProduct],
        '"' + [SupplierAcc1] + '"' AS [SupplierAcc1],
        '"' + CAST([TransAmt] AS VARCHAR(20)) + '"' AS [Value1],
        '"' + [TXNType1] + '"' AS [TXNType1],
        '"' + CAST([UltraMA] AS VARCHAR(30)) + '"' AS [UltraMA],
        '"' + CAST([TerminalID1] AS VARCHAR(20)) + '"' AS [TerminalID1],
        '"' + CAST([DealerCode] AS VARCHAR(20)) + '"' AS [DealerCode],
        '"' + [RetailerName] + '"' AS [RetailerName],
        '"' + [Address1] + '"' AS [Address1],
        '"' + [Address2] + '"' AS [Address2],
        '"' + [Address3] + '"' AS [Address3],
        '"' + [Address4] + '"' AS [Address4],
        '"' + CAST([PostCode] AS VARCHAR(20)) + '"' AS [PostCode]
    FROM
        CTE2
    CROSS JOIN dbo.CarrierDealerDiscount AS cdd --KMH20211117
    WHERE
        cdd.ParentCompany_ID = 2 --Ultra Mobile
    ORDER BY
        [TransID],
        [Reference_ID];
END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
-- noqa: disable=all
/
