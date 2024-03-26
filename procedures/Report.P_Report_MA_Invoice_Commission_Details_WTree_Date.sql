--liquibase formatted sql

--changeset KarinaMasihHudson:50bb507468f1460eb7e04b0cb282fe60 stripComments:false runOnChange:true splitStatements:false
/*==========================================================================================
    Rework   : Dana Jones
    Date     : June 28, 2023
        Original Author : Jacob Lowe
        Original Create Date : 2016-03-24
 Description : Pulls orders that make up MA invoice
             : Created new stored procedure for MAINT-36 Create Customized Reporting for Victra
             : This is based on original procedure [Report].[P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions] by JLowe
 DJJ20230517 : For card Maint-30 Victra reports
             : MA  - Invoice Commission Details with Tree Commissions Report Add columns
             :            ESN/MEID/IMEI
             :            SIM Card Number/ICCID
             :            Purchase Order #
             :            Product Sku (T-CETRA Product ID)
             :            Location Name
             :            MA Invoice #
             :            Direct Parent Commission Amount
             :            Direct Parent Commission Due Date
             :   Add temp table cleanup
             :   Total rework of how invoice number is handled
 DJJ20230628 : Rework to use dates instead of "invoice number"
             : see CRM report MA - Invoice Commission Details with Tree Commissions Victra Date
 KMH20230831 : Added Username/ID to report; updated to be open to all MAs
             :  renamed from MA - Invoice Commission Details with Tree Commissions Victra Date to
 NG20231010  : Added Residuals to WHERE clause to 2nd option on report to remove them from results pane
				 MA - Invoice Commission Details with Tree Commissions Date
  BS20231106 : Added MA Name
 KMH20231121 : Implemented the changes MR made in P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions
		MR20231108 : Re-arranged so that all the logic to further split apart option 0 and 1 so that Option 0
						can run with "AND oc.Commission_Amt <> 0.00" in the #ListOfOrders section to improve performance
						and so that option 1 can run without SIMS and ESNs pulled in due to the larger run time with
						including zero commissions.
				   : Added filled, void, processed flags in #ListOfOrders
				   : In the #PAK section, added #DistinctOrders0 table to eliminate duplicates, added a status check,
					    limited to order types 22 and 23, deleted any SIMs less than length of 12, and took the MIN of the
						SIMs to eliminate duplicates.
				   : In the #orderAuth section, added a #PreOrderAuth table to bring in the SKU and joined on this SKU
					    in the #orderAuth section to eliminate duplicates. Added filled, void, and processed flag checks here.
				   : Added DISTINCT to the #OIAAuth and #OIA sections and removed the OrderItemAddons and the AddonsID.
				   : Added the #MAXtspTransactionFeed section to just take the MAX to eliminate duplicates.
				   : Added error message to not be able to view the whole tree if pulling in zero dollar commissions.
				   : Removed "DISTINCT" from the final results due to not bringing back all the rows.
				   : Broke the logic fully into @Option 0 and @Option 1 so that all of the logic AND oc.Commission_Amt <> 0.00;
 KMH20240123 : Updated column list order for option 0; has to be in specific order for Victra
 KMH20240301 : Updated to display all MA Names/IDs, account is MA self report as MA, SIM cards showing SIM
			   Add IMEI/ICCID for Autopay Residuals
			   Made sure subsidies only come in if activation is filled; bring in subsidies for newly filled activations
			   Add UniqueID Combine Order ID and Parent id (commission parent id the parent who receive the commission )
			   Add $0 commission line for all MAs in an account tree not already being reported
			   Added these changes from P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions:
	--  MR20231129 : Took out the "DISTINCT" in the #ListOfCommInfo sections and add the SUM of commission_Amt
				   : Removed Commission_Amt DECIMAL(9,2), OrderType_ID INT from #ListOfOrders1
	--  MR20240215 : Removed join to product carrier mapping table in both options' final select statements.
					 Add Fee column and Retail Cost column.
==========================================================================================
         Usage : EXEC [Report].[P_Report_MA_Invoice_Commission_Details_WTree_Date] 155536,'20230801','20230802'
==========================================================================================*/
ALTER PROCEDURE [Report].[P_Report_MA_Invoice_Commission_Details_WTree_Date]
    (
        @StartDate DATE,
        @EndDate DATE,
        @Option INT,
        @sessionID INT
    )
AS

BEGIN TRY
------testing
    -- DECLARE
    -- @StartDate DATE = '2023-03-01' --NULL--DATEADD(MONTH,-1,CONVERT(DATE,GETDATE()))--'20231001'
    -- , @EndDate DATE = '2024-03-12' --NULL --CONVERT(DATE,GETDATE()) --20231018'
    -- , @SessionID INT = 155536 --156792 --155536
    -- , @Option INT = 1;
    -- NOTE: Victra AccountID = 155536

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF
        NOT EXISTS
        (
            SELECT Account_ID
            FROM CellDay_Prod.dbo.Account
            WHERE
                Account_ID = @sessionID
                AND AccountType_ID IN (5, 6, 8)
        )
        BEGIN
            SELECT 'This report is highly restricted! If you need access, please see your T-Cetra representative.' AS [Error Message];
            RETURN;
        END;

    -------------------------------------------------------------------------------------------------------------------------

    IF @StartDate IS NULL
        SET @StartDate = CONVERT(DATE, DATEADD(DAY, -1, GETDATE()));

    IF @EndDate IS NULL
        SET @EndDate = CONVERT(DATETIME, CONVERT(DATE, GETDATE()));

    -- SELECT @StartDate, @EndDate;
    IF (@StartDate > @EndDate)
        RAISERROR ('"Start Date:" can not be later than the "End Date:", please re-enter your dates!', 11, 1);

    --------------------------------------------------------------------------------------------------------------------------


    DROP TABLE IF EXISTS #ListOfAccounts;

    CREATE TABLE #ListOfAccounts
    (
        AccountID INT,
        AccountName VARCHAR(100)
    ); --BS20231106

    IF
        (
            SELECT a.AccountType_ID
            FROM dbo.Account AS a
            WHERE a.Account_ID = @sessionID
        ) IN (5, 6, 8)
        BEGIN
            INSERT INTO #ListOfAccounts
            (
                AccountID
            )
            EXEC [Account].[P_Account_GetAccountList]
                @AccountID = @sessionID,              -- int
                @UserID = 1,                          -- int
                @AccountTypeID = '2,11,5,6,8',        -- varchar(50)
                @AccountStatusID = '0,1,2,3,4,5,6,7', -- varchar(50)
                @Simplified = 1;                      -- bit
        END;
    --
    INSERT INTO #ListOfAccounts
    (
        AccountID
    )
    SELECT @sessionID
    WHERE
        @sessionID NOT IN
        (
            SELECT AccountID FROM #ListOfAccounts
        );
    --    SELECT * FROM #ListOfAccounts where accountID = 155536;

    UPDATE loa
    SET loa.AccountName = a.Account_Name
    FROM #ListOfAccounts AS loa
    JOIN dbo.Account AS a
        ON a.Account_ID = loa.AccountID;



    IF @Option = 0 --NG20230925 (Do not show zero dollar commissions)
        BEGIN
            IF OBJECT_ID('tempdb..#ListOfOrders0') IS NOT NULL
                BEGIN
                    DROP TABLE #ListOfOrders0;
                END;

            CREATE TABLE #ListOfOrders0
            (
                Orders_ID INT,
                Order_No INT,
                AuthNumber BIGINT,
                DateFilled DATETIME,
                OrderType_ID INT,
                User_ID INT,
                UserName NVARCHAR(50),
                Account_ID INT --KMH20240301
            );

            INSERT INTO #ListOfOrders0
            (
                Orders_ID,
                Order_No,
                AuthNumber,
                DateFilled,
                OrderType_ID,
                User_ID,
                UserName,
                Account_ID
            )
            SELECT
                Oi.ID,
                Oi.Order_No,
                CONVERT(BIGINT, n.AuthNumber) AS AuthNumber,
                n.DateFilled,
                n.OrderType_ID,
                n.User_ID, --KMH20230831
                u.UserName, --KMH20230831
                l.AccountID
            FROM dbo.Order_No AS n
            JOIN dbo.Orders AS Oi
                ON n.Order_No = Oi.Order_No
            JOIN #ListOfAccounts AS l
                ON l.AccountID = n.Account_ID
            JOIN dbo.Users AS u
                ON u.User_ID = n.User_ID
            WHERE
                n.Filled = 1
                AND n.Void = 0
                AND n.Process = 1
                AND n.OrderType_ID NOT IN (12, 5, 6, 43, 44)
                AND n.DateFilled >= @StartDate
                AND n.DateFilled < @EndDate;



            --KMH20240301 Find promos where activation filled later
            INSERT INTO #ListOfOrders0
            (
                Orders_ID,
                Order_No,
                AuthNumber,
                DateFilled,
                OrderType_ID,
                User_ID,
                UserName,
                Account_ID
            )
            SELECT DISTINCT
                opromo.ID AS Orders_ID
                , opromo.Order_No
                , CONVERT(INT, odpromo.AuthNumber) AS AuthNumber
                , odpromo.DateFilled
                , odpromo.OrderType_ID
                , odpromo.User_ID
                , u.UserName
                , odpromo.Account_ID
            FROM #ListOfOrders0 AS lo
            JOIN dbo.Order_No AS odpromo
                ON odpromo.AuthNumber = CONVERT(VARCHAR(30), lo.Order_No)
            JOIN dbo.Orders AS opromo
                ON opromo.Order_No = odpromo.Order_No
            JOIN dbo.Users AS u
                ON u.User_ID = odpromo.User_ID
            WHERE
                lo.OrderType_ID IN (22, 23)
                AND odpromo.OrderType_ID IN (59, 60)
                AND odpromo.Process = 1
                AND odpromo.Filled = 1
                AND odpromo.Void = 0
                AND NOT EXISTS (SELECT TOP 1 1 FROM #ListOfOrders0 AS lo WHERE lo.Orders_ID = opromo.ID)

            --KMH20240301 Remove promos where activation hasnt been filled
            ; WITH CTEPendingAct AS (
                SELECT
                    lo.Orders_ID
                FROM #ListOfOrders0 AS lo
                JOIN dbo.Order_No AS od2	--act
                    ON
                        od2.Order_No = lo.AuthNumber
                        AND od2.ordertype_id IN (22, 23)
                WHERE
                    lo.OrderType_ID IN (59, 60)
                    AND (od2.Filled = 0 OR od2.void = 1)
            )
            DELETE
            --SELECT *
            FROM #ListOfOrders0
            WHERE EXISTS (SELECT TOP 1 1 FROM CTEPendingAct AS c WHERE c.Orders_ID = #ListOfOrders0.Orders_ID)


            CREATE INDEX idx_OrderID ON #ListOfOrders0 (Orders_ID); -- LUX
            CREATE INDEX idx_AuthNumber ON #ListOfOrders0 (AuthNumber); -- LUX

            DROP TABLE IF EXISTS #AccountTree; --KMH20240301

            ; WITH cteAccountTree AS (
                SELECT DISTINCT
                    d.Account_ID
                    , acc.Account_Name AS [ChildName]
                    , acc.ParentAccount_Account_ID
                    , acc.HierarchyString
                FROM #ListOfOrders0 AS d
                JOIN dbo.Account AS acc
                    ON acc.Account_ID = d.Account_ID
            )
            , cteHierarchy AS (
                SELECT
                    c.Account_ID
                    , c.ChildName
                    , c.ParentAccount_Account_ID
                    , c.HierarchyString
                    , ISNULL(CONVERT(INT, s.[value]), 0) AS ParentAccounts
                FROM cteAccountTree AS c
                CROSS APPLY STRING_SPLIT(c.HierarchyString, '/') AS s
            )
            SELECT
                h.Account_ID
                , h.HierarchyString
                , IIF(h.ParentAccounts = 2, h.Account_ID, h.ParentAccounts) AS ParentAccounts
                , IIF(h.ParentAccounts = 2, h.ChildName, acc.Account_Name) AS Account_Name
                , ROW_NUMBER() OVER (PARTITION BY h.Account_ID ORDER BY h.ParentAccounts) AS AccountTree
                , IIF(h.ParentAccounts = h.ParentAccount_Account_ID, 1, 0) AS IsDirectParent
            INTO #AccountTree
            FROM cteHierarchy AS h
            JOIN dbo.Account AS acc
                ON acc.Account_ID = h.ParentAccounts
            WHERE
                (
                    h.ParentAccounts NOT IN (0, 2)
                    OR (
                        h.ParentAccounts = 2
                        AND IIF(h.ParentAccounts = h.ParentAccount_Account_ID, 1, 0) = 1
                    )
                )
                AND h.Account_ID <> h.ParentAccounts

            DROP TABLE IF EXISTS #DistinctOrders0;
            SELECT DISTINCT
                lo.Order_No,
                lo.OrderType_ID --MR20231108
            INTO #DistinctOrders0
            FROM #ListOfOrders0 AS lo;

            DROP TABLE IF EXISTS #PrePAK; --MR20231108

            SELECT
                pak.order_no,
                pak.Sim_ID,
                LEN(pak.Sim_ID) AS LEN_SIM_ID,
                pak.PONumber
            INTO #PrePAK
            FROM #DistinctOrders0 AS lo
            JOIN dbo.Phone_Active_Kit AS pak
                ON
                    lo.Order_No = pak.order_no
                    AND pak.Status = 1
            WHERE lo.OrderType_ID IN (22, 23);

            DELETE pak
            FROM #PrePAK AS pak
            WHERE LEN(pak.Sim_ID) < 12;

            DROP TABLE IF EXISTS #PAK; -- LUX

            SELECT
                p.order_no, -- LUX
                MIN(p.Sim_ID) AS Sim_ID,
                MIN(p.LEN_SIM_ID) AS LEN_SIM_ID,
                MIN(ISNULL(p.PONumber, '')) AS PONumber
            INTO #PAK
            FROM #PrePAK AS p
            WHERE p.LEN_SIM_ID < 16
            GROUP BY p.order_no
            UNION
            SELECT
                p.order_no,
                MIN(p.Sim_ID) AS Sim_ID,
                MIN(p.LEN_SIM_ID) AS LEN_SIM_ID,
                MIN(ISNULL(p.PONumber, '')) AS PONumber
            FROM #PrePAK AS p
            WHERE p.LEN_SIM_ID > 16
            GROUP BY p.order_no;

            --------------------------------------------------------------------------------------------------------------
            --  Find order based on AuthNumber
            ------------------------------------------------------------------------------------------------------------
            DROP TABLE IF EXISTS #PreOrderAuth;

            SELECT
                o.Orders_ID,
                o.Order_No,
                o.AuthNumber,
                o.OrderType_ID,
                d.SKU
            INTO #PreOrderAuth
            FROM #ListOfOrders0 AS o
            JOIN dbo.Orders AS d
                ON d.ID = o.Orders_ID
            WHERE ISNULL(o.AuthNumber, '') <> '';

            DROP TABLE IF EXISTS #OrderAuth;

            SELECT
                d2.ID AS AuthOrderID,
                d2.Order_No,
                ord.Orders_ID AS OrgOrderId
            INTO #OrderAuth
            FROM dbo.Orders AS d2
            JOIN #PreOrderAuth AS ord
                ON
                    d2.Order_No = ord.AuthNumber
                    AND d2.SKU = ord.SKU
                    AND ISNULL(d2.ParentItemID, 0) IN (0, 1)
                    AND ISNULL(ord.AuthNumber, '') <> '' --MR20231108
            JOIN dbo.Order_No AS n
                ON
                    n.Order_No = ord.Order_No
                    AND n.Filled = 1 --MR20231108
                    AND n.Void = 0
                    AND n.Process = 1;

            --   --------------------------------------------------------------------------------------------------------------
            --   -- Get data tblOrderItemAddons based on orders
            --   --------------------------------------------------------------------------------------------------------------

            DROP TABLE IF EXISTS #OiA;

            SELECT DISTINCT --MR20231108 (Added distinct)
                A.OrderID,
                A.AddonsValue,
                f2.AddonTypeName
            INTO #OiA
            FROM #ListOfOrders0 AS B
            JOIN dbo.tblOrderItemAddons AS A
                ON B.Orders_ID = A.OrderID
            JOIN dbo.tblAddonFamily AS f2
                ON
                    f2.AddonID = A.AddonsID
                    AND f2.AddonTypeName IN ('SimType', 'SimBYOPType', 'DeviceType', 'DeviceBYOPType');

            --   --------------------------------------------------------------------------------------------------------------
            --   -- Get data tblOrderItemAddons based on AuthNumber
            --   --------------------------------------------------------------------------------------------------------------
            DROP TABLE IF EXISTS #OIAAuth;

            SELECT DISTINCT --MR20231108 (Added distinct)
                A.OrderID,
                A.AddonsValue,
                B.Order_No,
                f2.AddonTypeName
            INTO #OIAAuth
            FROM #OrderAuth AS B
            JOIN dbo.tblOrderItemAddons AS A
                ON B.AuthOrderID = A.OrderID
            JOIN dbo.tblAddonFamily AS f2
                ON
                    f2.AddonID = A.AddonsID
                    AND f2.AddonTypeName IN ('SimType', 'SimBYOPType', 'DeviceType', 'DeviceBYOPType');

            DROP TABLE IF EXISTS #Residual; --KMH20240301
            SELECT DISTINCT
                d.Orders_ID
                , d.Order_No
                , oiar.AddonsValue AS [SIM]
                , CASE
                    WHEN dcd.esn IS NOT NULL THEN dcd.ESN
                    WHEN
                        LEN(oia.AddonsValue) BETWEEN 15 AND 16
                        AND ISNUMERIC(oia.AddonsValue) = 1
                        THEN oia.AddonsValue
                    ELSE ''
                END AS [ESN]
            INTO #Residual
            FROM #ListOfOrders0 AS d
            JOIN dbo.tblOrderItemAddons AS oiar
                ON oiar.OrderID = d.Orders_ID
            JOIN dbo.tblOrderItemAddons AS oias
                ON oias.AddonsValue = oiar.AddonsValue
            JOIN
                dbo.tblOrderItemAddons AS oia
                    LEFT JOIN dbo.tblAddonFamily AS aof
                        ON
                            aof.AddonID = oia.AddonsID
                            AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
                ON oias.OrderID = oia.OrderID
            LEFT JOIN Tracfone.tblDealerCommissionDetail AS dcd
                ON
                    dcd.SIM = oiar.AddonsValue
                    AND dcd.COMMISSION_TYPE IN ('AUTOPAY ENROLLMENT', 'AUTOPAY RESIDUAL')
            LEFT JOIN
                dbo.Orders AS o
                    JOIN dbo.Order_No AS od
                        ON
                            od.Order_No = o.Order_No
                            AND od.OrderType_ID IN (22, 23)
                ON
                    oia.OrderID = o.ID
                    AND ISNULL(o.ParentItemID, 0) = 0
            WHERE d.OrderType_ID IN (28, 38)

            ----For historical runs as dcd only keeps few weeks of data
            -- INSERT INTO #Residual
            -- SELECT DISTINCT
            -- d.Orders_ID
            -- , d.Order_No
            -- , oiar.AddonsValue AS [SIM]
            -- , CASE
            -- WHEN dcd.esn IS NOT NULL THEN dcd.ESN
            -- WHEN
            -- LEN(oia.AddonsValue) BETWEEN 15 AND 16
            -- AND ISNUMERIC(oia.AddonsValue) = 1
            -- THEN oia.AddonsValue
            -- ELSE ''
            -- END AS [ESN]
            -- FROM #ListOfOrders0 AS d
            -- JOIN dbo.tblOrderItemAddons AS oiar
            -- ON oiar.OrderID = d.Orders_ID
            -- JOIN dbo.tblOrderItemAddons AS oias
            -- ON oias.AddonsValue = oiar.AddonsValue
            -- JOIN
            -- dbo.tblOrderItemAddons AS oia
            -- LEFT JOIN dbo.tblAddonFamily AS aof
            -- ON
            -- aof.AddonID = oia.AddonsID
            -- AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            -- ON oias.OrderID = oia.OrderID
            -- LEFT JOIN CellDay_History.Tracfone.tblDealerCommissionDetail AS dcd
            -- ON
            -- dcd.SIM = oiar.AddonsValue
            -- AND dcd.COMMISSION_TYPE IN ('AUTOPAY ENROLLMENT', 'AUTOPAY RESIDUAL')
            -- LEFT JOIN
            -- dbo.Orders AS o
            -- JOIN dbo.Order_No AS od
            -- ON
            -- od.Order_No = o.Order_No
            -- AND od.OrderType_ID IN (22, 23)
            -- ON
            -- oia.OrderID = o.ID
            -- AND ISNULL(o.ParentItemID, 0) = 0
            -- WHERE d.OrderType_ID IN (28, 38)
            --

            IF OBJECT_ID('tempdb..#ListOfCommInfo0') IS NOT NULL
                BEGIN
                    DROP TABLE #ListOfCommInfo0;
                END;

            ; WITH cteListOfCommissions AS (
                SELECT --MR20220325
                    oc.Orders_ID,
                    oc.Account_ID,
                    oc.Commission_Amt,
                    oc.InvoiceNum,
                    oc.Datedue,
                    la.AccountName, --BS20231106
                    CONCAT(oc.Orders_ID, oc.Order_Commission_SK) AS UniqueID --KMH20240301
                FROM dbo.Order_Commission AS oc
                JOIN #ListOfAccounts AS la
                    ON la.AccountID = oc.Account_ID
                WHERE
                    oc.Account_ID <> 2
                    AND oc.Commission_Amt <> 0
                    AND EXISTS
                    (
                        SELECT 1 FROM #ListOfOrders0 AS lo WHERE lo.Orders_ID = oc.Orders_ID
                    )
            )
            SELECT
                lc.Orders_ID
                , lc.Account_ID
                , lc.InvoiceNum		--MR20231129
                , lc.Datedue
                , lc.AccountName --BS20231106
                , SUM(lc.Commission_Amt) AS Commission_Amt
                , CONVERT(VARCHAR(MAX), n.Order_No) AS [MaInvoiceNumber]
                , CONVERT(DATETIME, n.DateDue) AS [MADateDue]
                , lc.UniqueID
            INTO #ListOfCommInfo0
            FROM cteListOfCommissions AS lc
            LEFT JOIN dbo.Order_No AS n
                ON
                    lc.InvoiceNum = n.InvoiceNum
                    AND lc.InvoiceNum IS NOT NULL
                    AND n.Account_ID = lc.Account_ID
                    AND n.OrderType_ID IN (5, 6)
            GROUP BY
                CONVERT(VARCHAR(MAX), n.Order_No),
                n.DateDue,
                lc.Orders_ID,
                lc.Account_ID,
                lc.InvoiceNum,
                lc.Datedue,
                lc.AccountName,
                lc.UniqueID;

            INSERT INTO #ListOfCommInfo0 --KMH20240301
            (
                Orders_ID, Account_ID, Commission_Amt, InvoiceNum, Datedue
                , AccountName, UniqueID
            )
            SELECT
                d.Orders_ID
                , d.ParentAccounts
                , d.Commission_Amt
                , d.MAInvoiceNumber
                , d.Datedue
                , d.Account_Name
                , d.UniqueID
            FROM
                (
                    SELECT
                        d.Orders_ID
                        , act.ParentAccounts
                        , 0.00 AS Commission_Amt
                        , 0 AS MAInvoiceNumber
                        , '1900-01-01' AS Datedue
                        , act.Account_Name
                        , CONCAT(d.Orders_ID, act.ParentAccounts) AS UniqueID
                    FROM #ListOfOrders0 AS d
                    JOIN #AccountTree AS act
                        ON act.Account_ID = d.Account_ID
                    WHERE
                        NOT EXISTS (
                            SELECT TOP 1 1
                            FROM #ListOfCommInfo0 AS lc
                            WHERE
                                d.Orders_ID = lc.Orders_ID
                                AND lc.Account_ID = act.ParentAccounts
                        )
                ) AS d


            IF OBJECT_ID('tempdb..#ProductCategory0') IS NOT NULL
                BEGIN
                    DROP TABLE #ProductCategory0;
                END;

            SELECT
                lo.Orders_ID,
                o.Name,
                o.Product_ID,
                CASE
                    WHEN pt.ProductTypeName = 'PinRtr'
                        THEN
                            'Airtime'
                    WHEN ISNULL(pt.ProductTypeName, 'PIN') = 'PIN'
                        THEN
                            'Airtime'
                    WHEN pt.ProductTypeName = 'RTR'
                        THEN
                            'Airtime'
                    WHEN pt.ProductTypeName = 'Sim'
                        THEN
                            'SIM'
                    WHEN pt.ProductTypeName = 'CredCardValidation'
                        THEN
                            'Credit Card Validation'
                    WHEN pt.ProductTypeName = 'CredCardDeposit'
                        THEN
                            'Credit Card Deposit'
                    WHEN
                        pt.ProductTypeName = 'FeeProduct'
                        AND p.Product_ID = 8927
                        THEN
                            'Merchant Processing'
                    WHEN
                        pt.ProductTypeName = 'FeeProduct'
                        AND p.Product_ID <> 8927
                        THEN
                            'Fee'
                    WHEN pt.ProductTypeName = 'CashDeposit'
                        THEN
                            'Cash Deposit'
                    WHEN pt.ProductTypeName = 'ActivationFee'
                        THEN
                            'Activation Fee'
                    WHEN pt.ProductTypeName = 'SpiffSplit'
                        THEN
                            'Spiff: Additional Month Spiff'
                    WHEN pt.ProductTypeName = 'BillPay'
                        THEN
                            'Bill Pay'
                    WHEN pt.ProductTypeName = 'CreditCardVerification'
                        THEN
                            'Credit Card Verification'
                    WHEN pt.ProductTypeName = 'ConsumerPromotion'
                        THEN
                            'Consumer Promotion'
                    WHEN pt.ProductTypeName = 'TradeIn'
                        THEN
                            'Trade-In'
                    WHEN pt.ProductTypeName = 'Marketplace'
                        THEN
                            CASE
                                WHEN p.SubProductTypeId = 5
                                    THEN
                                        'Marketplace: SIM Cards'
                                WHEN p.SubProductTypeId IN (2, 3, 4, 6, 7, 8)
                                    THEN
                                        'Marketplace: Unlocked Handsets'
                                WHEN
                                    p.SubProductTypeId = 10
                                    AND pa.Value IN ('laptop', '2n1', 'tablet')
                                    THEN
                                        'Marketplace: Tablets and Laptops'
                                WHEN
                                    p.SubProductTypeId = 10
                                    AND ISNULL(pa.Value, '') NOT IN ('laptop', '2n1', 'tablet')
                                    THEN
                                        'Marketplace: Accessories'
                                WHEN p.SubProductTypeId = 13
                                    THEN
                                        'Marketplace: Marketing Materials'
                                ELSE
                                    'Marketplace: Other'
                            END
                    WHEN pt.ProductTypeName = 'Branded Handset'
                        THEN
                            'Marketplace: Branded Handset'
                    ELSE
                        pt.ProductTypeName
                END AS [ProductTypeName],
                o.Price,
                o.DiscAmount,
                ISNULL(o.Fee, 0.00) AS Fee, --MR20240215
                o.Product_ID AS [Product SKU] --KMH20230831
            INTO #ProductCategory0
            FROM #ListOfOrders0 AS lo
            JOIN dbo.Orders AS o
                ON o.ID = lo.Orders_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS CarrMap
                ON o.Product_ID = CarrMap.ProductId
            LEFT JOIN Products.tblProductType AS pt
                ON pt.ProductTypeID = p.Product_Type
            LEFT JOIN MarketPlace.tblProductAttributes AS pa
                ON
                    pa.Product_ID = p.Product_ID
                    AND pa.AttributeID = 13;


            DROP TABLE IF EXISTS #MAXtspTransactionFeed;

            SELECT
                MAX(f.TSPTransactionFeedID) AS FeedID,
                lo.Order_No
            INTO #MAXtspTransactionFeed
            FROM #DistinctOrders0 AS lo
            JOIN Tracfone.tblTSPTransactionFeed AS f
                ON f.Order_No = lo.Order_No
            WHERE ISNULL(f.TXN_PIN, '') <> ''
            GROUP BY lo.Order_No;

            DROP TABLE IF EXISTS #tspTransactionFeed;

            SELECT
                f.Order_No,
                f.TXN_PIN
            INTO #tspTransactionFeed
            FROM Tracfone.tblTSPTransactionFeed AS f
            JOIN #MAXtspTransactionFeed AS tf
                ON f.TSPTransactionFeedID = tf.FeedID;

            WITH MyCte AS (
                SELECT
                    n.Order_No,
                    pc1.Name AS [Product],
                    pc1.Product_ID,
                    pc1.ProductTypeName,
                    pc1.Price,
                    pc1.DiscAmount,
                    pc1.Fee,
                    n.Account_ID,
                    n.DateOrdered,
                    n.DateFilled,                                                                             --KMH20230831
                    IIF(ISNULL(lci.Account_ID, '') LIKE '', ISNULL(act.ParentAccounts, ''), lci.Account_ID) AS MA,	--KMH20240301
                    ISNULL(lci.AccountName, ISNULL(act.Account_Name, '')) AS [MA_AccountName], --KMH20240301
                    lci.Commission_Amt AS [MaCommissionAmount],
                    lci.Datedue AS [DateDue],                                                                 --KMH20230831
                    ISNULL(lci.MaInvoiceNumber, '') AS [MaInvoiceNumber],
                    ISNULL(pakSIM.Sim_ID, ISNULL(OIAAuthSIM.AddonsValue, ISNULL(OIAOSIM.AddonsValue, '')))
                        AS [SIM],                       --KMH20230831
                    COALESCE(pakESN.Sim_ID, OIAAuthESN.AddonsValue, OIAOESN.AddonsValue, tf.TXN_PIN, r.ESN, '') AS ESN, --KMH20230831
                    pakSIM.PONumber AS PONumber,                                                              --KMH20230831
                    pc1.[Product SKU],
                    cust.Company AS [Company],                                                                --KMH20230831
                    n.User_ID AS [UserID],                                                                    --KMH20230831
                    u.UserName AS [username],                                                                 --KMH20230831
                    lci.UniqueID --KMH20240221
                FROM #ListOfOrders0 AS lo
                JOIN dbo.Order_No AS n
                    ON n.Order_No = lo.Order_No
                JOIN #ProductCategory0 AS pc1
                    ON pc1.Orders_ID = lo.Orders_ID
                JOIN dbo.Users AS u
                    ON u.User_ID = n.User_ID
                JOIN #AccountTree AS act --KMH20240301
                    ON
                        act.Account_ID = lo.Account_ID
                        AND act.IsDirectParent = 1
                LEFT JOIN #ListOfCommInfo0 AS lci
                    ON lci.Orders_ID = lo.Orders_ID
                JOIN dbo.Customers AS cust
                    ON n.Customer_ID = cust.Customer_ID
                LEFT JOIN #PAK AS pakSIM -- LUX
                    ON
                        pakSIM.order_no = n.Order_No
                        AND pakSIM.LEN_SIM_ID > 16
                LEFT JOIN #PAK AS pakESN -- LUX
                    ON
                        pakESN.order_no = n.Order_No
                        AND pakESN.LEN_SIM_ID < 16
                LEFT JOIN #OrderAuth AS d2
                    ON d2.OrgOrderId = lo.Orders_ID
                LEFT JOIN #OIAAuth AS OIAAuthSIM
                    ON
                        OIAAuthSIM.OrderID = d2.AuthOrderID
                        AND OIAAuthSIM.AddonTypeName IN ('SimType', 'SimBYOPType')
                LEFT JOIN #OIAAuth AS OIAAuthESN
                    ON
                        OIAAuthESN.OrderID = d2.AuthOrderID
                        AND OIAAuthESN.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
                LEFT JOIN #OiA AS OIAOESN
                    ON
                        OIAOESN.OrderID = lo.Orders_ID
                        AND OIAOESN.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
                LEFT JOIN #OiA AS OIAOSIM --KMH20240301
                    ON
                        OIAOSIM.OrderID = lo.Orders_ID
                        AND OIAOSIM.AddonTypeName IN ('SimType', 'SimBYOPType')
                LEFT JOIN #Residual AS r --KMH20240301
                    ON r.Orders_ID = lo.Orders_ID
                LEFT JOIN #tspTransactionFeed AS tf
                    ON tf.Order_No = lo.Order_No
            )
            --AS202020318 #INC-338347

            SELECT
                m.Order_No,
                m.DateFilled,                               --KMH20230831
                m.Product,
                m.ProductTypeName,
                CASE
                    WHEN m.ProductTypeName = 'Activation'
                        THEN
                            C2.Name --NG20210426
                    WHEN m.Product_ID = 10428
                        THEN
                            'Merchant Service Commission'
                    ELSE
                        C.Name
                END AS [ProductCategory],
                CASE
                    WHEN m.ProductTypeName = 'Activation'
                        THEN
                            IIF(m.Product_ID = 10428, 'Merchant Service Commission', C.Name) --NG20210426
                    ELSE
                        ''
                END AS ProductSubCategory,
                m.Price,
                m.DiscAmount,
                m.Fee,
                (m.Price - m.DiscAmount + m.Fee) AS RetailCost, --MR20240215
                m.Account_ID,
                m.DateOrdered,
                CONVERT(VARCHAR(20), m.[MaCommissionAmount]) AS [MaCommissionAmount],
                m.DateDue AS DirectParentCommissionDateDue, --KMH20230831			--KMH20230831
                m.[MaInvoiceNumber],
                m.SIM,                                      --KMH20230831
                m.ESN,                                      --KMH20230831
                m.PONumber,                                 --KMH20230831
                m.[Product SKU],                            --KMH20230831
                m.Company,                                  --KMH20230831
                m.UserID,                                   --KMH20230831
                m.username,                                 --KMH20230831
                m.[MA],
                m.MA_AccountName,
                m.UniqueID
            FROM MyCte AS m
            LEFT JOIN dbo.Product_Category AS PC WITH (READUNCOMMITTED)
                ON m.Product_ID = PC.Product_ID
            LEFT JOIN dbo.Categories AS C WITH (READUNCOMMITTED)
                ON PC.Category_ID = C.Category_ID
            LEFT JOIN dbo.Categories AS C2 WITH (READUNCOMMITTED)
                ON C2.Category_ID = C.Parent_ID --NG20210426
            ORDER BY
                m.Order_No,
                m.MA;

        --AS202020318 #INC-338347

        END;

    IF @Option = 1 --NG20230925 (Show zero dollar commissions. Logged in account only).
        BEGIN

            IF OBJECT_ID('tempdb..#ListOfOrders1') IS NOT NULL
                BEGIN
                    DROP TABLE #ListOfOrders1;
                END;

            CREATE TABLE #ListOfOrders1
            (
                Orders_ID INT,
                Order_No INT, --AuthNumber INT,
                DateFilled DATETIME,
                OrderType_ID INT,
                User_ID INT,
                UserName NVARCHAR(50),
                Account_ID INT --KMH20240221
            );

            INSERT INTO #ListOfOrders1
            (
                Orders_ID,
                Order_No, --AuthNumber,
                DateFilled,
                OrderType_ID,
                User_ID,
                UserName,
                Account_ID
            )
            SELECT
                Oi.ID,
                Oi.Order_No,
                --, CONVERT( INT, AuthNumber ) AuthNumber
                n.DateFilled,
                n.OrderType_ID,
                n.User_ID, --KMH20230831
                u.UserName, --KMH20230831
                l.AccountID
            FROM dbo.Order_No AS n
            JOIN dbo.Orders AS Oi
                ON n.Order_No = Oi.Order_No
            JOIN #ListOfAccounts AS l
                ON l.AccountID = n.Account_ID
            JOIN dbo.Users AS u
                ON u.User_ID = n.User_ID
            WHERE
                n.Filled = 1
                AND n.Void = 0
                AND n.Process = 1
                AND n.OrderType_ID NOT IN (12, 5, 6, 43, 44)
                AND n.DateFilled >= @StartDate
                AND n.DateFilled < @EndDate;
            --Select * from #ListOfOrders1


            CREATE INDEX idx_OrderID ON #ListOfOrders1 (Orders_ID); -- LUX

            DROP TABLE IF EXISTS #AccountTree0; --KMH20240301

            ; WITH cteAccountTree AS (
                SELECT DISTINCT
                    d.Account_ID
                    , acc.Account_Name AS [ChildName]
                    , acc.ParentAccount_Account_ID
                    , acc.HierarchyString
                FROM #ListOfOrders1 AS d
                JOIN dbo.Account AS acc
                    ON acc.Account_ID = d.Account_ID
            )
            , cteHierarchy AS (
                SELECT
                    c.Account_ID
                    , c.ChildName
                    , c.ParentAccount_Account_ID
                    , c.HierarchyString
                    , ISNULL(CONVERT(INT, s.[value]), 0) AS ParentAccounts
                FROM cteAccountTree AS c
                CROSS APPLY STRING_SPLIT(c.HierarchyString, '/') AS s
            )
            SELECT
                h.Account_ID
                , h.HierarchyString
                , IIF(h.ParentAccounts = 2, h.Account_ID, h.ParentAccounts) AS ParentAccounts
                , IIF(h.ParentAccounts = 2, h.ChildName, acc.Account_Name) AS Account_Name
                , ROW_NUMBER() OVER (PARTITION BY h.Account_ID ORDER BY h.ParentAccounts) AS AccountTree
                , IIF(h.ParentAccounts = h.ParentAccount_Account_ID, 1, 0) AS IsDirectParent
            INTO #AccountTree0
            FROM cteHierarchy AS h
            JOIN dbo.Account AS acc
                ON acc.Account_ID = h.ParentAccounts
            WHERE
                (
                    h.ParentAccounts NOT IN (0, 2)
                    OR (
                        h.ParentAccounts = 2
                        AND IIF(h.ParentAccounts = h.ParentAccount_Account_ID, 1, 0) = 1
                    )
                )
                AND h.Account_ID <> h.ParentAccounts

            IF OBJECT_ID('tempdb..#ListOfCommInfo1') IS NOT NULL
                BEGIN
                    DROP TABLE #ListOfCommInfo1;
                END;


            ; WITH cteListOfCommissions AS (
                SELECT --MR20220325
                    oc.Orders_ID,
                    oc.Account_ID,
                    oc.Commission_Amt,
                    oc.InvoiceNum,
                    oc.Datedue,
                    la.AccountName,
                    CONCAT(oc.Orders_ID, oc.Order_Commission_SK) AS UniqueID --KMH20240301
                FROM dbo.Order_Commission AS oc
                JOIN #ListOfAccounts AS la
                    ON
                        la.AccountID = oc.Account_ID
                        AND la.AccountID = @sessionID
                WHERE
                    oc.Account_ID <> 2
                    AND EXISTS
                    (
                        SELECT 1 FROM #ListOfOrders1 AS lo WHERE lo.Orders_ID = oc.Orders_ID
                    )
            )
            SELECT
                lc.Orders_ID
                , lc.Account_ID
                , lc.InvoiceNum
                , lc.Datedue
                , SUM(lc.Commission_Amt) AS Commission_Amt
                , CONVERT(VARCHAR(MAX), n.Order_No) AS [MaInvoiceNumber]
                , CONVERT(DATETIME, n.DateDue) AS [MADateDue]
                , lc.AccountName
                , lc.UniqueID
            INTO #ListOfCommInfo1
            FROM cteListOfCommissions AS lc
            LEFT JOIN dbo.Order_No AS n
                ON
                    lc.InvoiceNum = n.InvoiceNum
                    AND lc.InvoiceNum IS NOT NULL
                    AND n.Account_ID = lc.Account_ID
                    AND n.OrderType_ID IN (5, 6)
            GROUP BY
                CONVERT(VARCHAR(MAX), n.Order_No),
                n.DateDue,
                lc.Orders_ID,
                lc.Account_ID,
                lc.InvoiceNum,
                lc.Datedue,
                lc.AccountName,
                lc.UniqueID;

            INSERT INTO #ListOfCommInfo1 --KMH20240301
            (
                Orders_ID, Account_ID, Commission_Amt, InvoiceNum, Datedue
                , AccountName, UniqueID
            )
            SELECT
                d.Orders_ID
                , d.ParentAccounts
                , d.Commission_Amt
                , d.MAInvoiceNumber
                , d.Datedue
                , d.Account_Name
                , d.UniqueID
            FROM
                (
                    SELECT
                        d.Orders_ID
                        , act.ParentAccounts
                        , 0.00 AS Commission_Amt
                        , 0 AS MAInvoiceNumber
                        , '1900-01-01' AS Datedue
                        , act.Account_Name
                        , CONCAT(d.Orders_ID, act.ParentAccounts) AS UniqueID
                    FROM #ListOfOrders1 AS d
                    JOIN #AccountTree0 AS act
                        ON act.Account_ID = d.Account_ID
                    WHERE
                        NOT EXISTS (
                            SELECT TOP 1 1
                            FROM #ListOfCommInfo1 AS lc
                            WHERE
                                d.Orders_ID = lc.Orders_ID
                                AND lc.Account_ID = act.ParentAccounts
                        )
                ) AS d


            IF OBJECT_ID('tempdb..#ProductCategory1') IS NOT NULL
                BEGIN
                    DROP TABLE #ProductCategory1;
                END;

            SELECT
                lo.Orders_ID,
                o.Name,
                o.Product_ID,
                CASE
                    WHEN pt.ProductTypeName = 'PinRtr'
                        THEN
                            'Airtime'
                    WHEN ISNULL(pt.ProductTypeName, 'PIN') = 'PIN'
                        THEN
                            'Airtime'
                    WHEN pt.ProductTypeName = 'RTR'
                        THEN
                            'Airtime'
                    WHEN pt.ProductTypeName = 'Sim'
                        THEN
                            'SIM'
                    WHEN pt.ProductTypeName = 'CredCardValidation'
                        THEN
                            'Credit Card Validation'
                    WHEN pt.ProductTypeName = 'CredCardDeposit'
                        THEN
                            'Credit Card Deposit'
                    WHEN
                        pt.ProductTypeName = 'FeeProduct'
                        AND p.Product_ID = 8927
                        THEN
                            'Merchant Processing'
                    WHEN
                        pt.ProductTypeName = 'FeeProduct'
                        AND p.Product_ID <> 8927
                        THEN
                            'Fee'
                    WHEN pt.ProductTypeName = 'CashDeposit'
                        THEN
                            'Cash Deposit'
                    WHEN pt.ProductTypeName = 'ActivationFee'
                        THEN
                            'Activation Fee'
                    WHEN pt.ProductTypeName = 'SpiffSplit'
                        THEN
                            'Spiff: Additional Month Spiff'
                    WHEN pt.ProductTypeName = 'BillPay'
                        THEN
                            'Bill Pay'
                    WHEN pt.ProductTypeName = 'CreditCardVerification'
                        THEN
                            'Credit Card Verification'
                    WHEN pt.ProductTypeName = 'ConsumerPromotion'
                        THEN
                            'Consumer Promotion'
                    WHEN pt.ProductTypeName = 'TradeIn'
                        THEN
                            'Trade-In'
                    WHEN pt.ProductTypeName = 'Marketplace'
                        THEN
                            CASE
                                WHEN p.SubProductTypeId = 5
                                    THEN
                                        'Marketplace: SIM Cards'
                                WHEN p.SubProductTypeId IN (2, 3, 4, 6, 7, 8)
                                    THEN
                                        'Marketplace: Unlocked Handsets'
                                WHEN
                                    p.SubProductTypeId = 10
                                    AND pa.Value IN ('laptop', '2n1', 'tablet')
                                    THEN
                                        'Marketplace: Tablets and Laptops'
                                WHEN
                                    p.SubProductTypeId = 10
                                    AND ISNULL(pa.Value, '') NOT IN ('laptop', '2n1', 'tablet')
                                    THEN
                                        'Marketplace: Accessories'
                                WHEN p.SubProductTypeId = 13
                                    THEN
                                        'Marketplace: Marketing Materials'
                                ELSE
                                    'Marketplace: Other'
                            END
                    WHEN pt.ProductTypeName = 'Branded Handset'
                        THEN
                            'Marketplace: Branded Handset'
                    ELSE
                        pt.ProductTypeName
                END AS [ProductTypeName],
                o.Price,
                o.DiscAmount,
                ISNULL(o.Fee, 0.00) AS Fee,
                o.Product_ID AS [Product SKU] --KMH20230831
            INTO #ProductCategory1
            FROM #ListOfOrders1 AS lo
            JOIN dbo.Orders AS o
                ON o.ID = lo.Orders_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS CarrMap
                ON o.Product_ID = CarrMap.ProductId
            LEFT JOIN Products.tblProductType AS pt
                ON pt.ProductTypeID = p.Product_Type
            LEFT JOIN MarketPlace.tblProductAttributes AS pa
                ON
                    pa.Product_ID = p.Product_ID
                    AND pa.AttributeID = 13;

            WITH MyCte AS (
                SELECT
                    n.Order_No,
                    pc1.Name AS [Product],
                    pc1.Product_ID,
                    pc1.ProductTypeName,
                    pc1.Price,
                    pc1.DiscAmount,
                    pc1.Fee,
                    n.Account_ID,
                    n.DateOrdered,
                    n.DateFilled,                        --KMH20230831
                    ISNULL(act.ParentAccounts, ISNULL(lci.Account_ID, '')) AS MA,	--KMH20240301
                    ISNULL(act.Account_Name, ISNULL(lci.AccountName, '')) AS [MA_AccountName], --KMH20240301
                    lci.Commission_Amt AS [MaCommissionAmount],
                    lci.Datedue AS [DateDue],            --KMH20230831
                    ISNULL(lci.MaInvoiceNumber, '') AS [MaInvoiceNumber],
                    pc1.[Product SKU],
                    cust.Company AS [Company],           --KMH20230831
                    n.User_ID AS [UserID],               --KMH20230831
                    u.UserName AS [Username],             --KMH20230831
                    IIF(lci.UniqueID IS NULL, CONCAT(lo.Orders_ID, act.ParentAccounts), lci.UniqueID) AS UniqueID --KMH20240221
                FROM #ListOfOrders1 AS lo
                JOIN dbo.Order_No AS n
                    ON n.Order_No = lo.Order_No
                JOIN #AccountTree0 AS act --KMH20240301
                    ON
                        act.Account_ID = lo.Account_ID
                        AND act.IsDirectParent = 1
                -- JOIN dbo.Account AS acc --KMH20240301
                -- ON acc.Account_ID = n.Account_ID
                -- JOIN dbo.Account AS ma --KMH20240301
                -- ON ma.Account_ID = acc.ParentAccount_Account_ID
                JOIN #ProductCategory1 AS pc1
                    ON pc1.Orders_ID = lo.Orders_ID
                JOIN dbo.Users AS u
                    ON u.User_ID = n.User_ID
                LEFT JOIN #ListOfCommInfo1 AS lci
                    ON lci.Orders_ID = lo.Orders_ID
                JOIN dbo.Customers AS cust
                    ON n.Customer_ID = cust.Customer_ID
            )
            --AS202020318 #INC-338347

            SELECT
                m.Order_No,
                m.DateFilled,
                m.Product,
                m.ProductTypeName,
                CASE
                    WHEN m.ProductTypeName = 'Activation'
                        THEN
                            C2.Name --NG20210426
                    WHEN m.Product_ID = 10428
                        THEN
                            'Merchant Service Commission'
                    ELSE
                        C.Name
                END AS [ProductCategory],
                CASE
                    WHEN m.ProductTypeName = 'Activation'
                        THEN
                            IIF(m.Product_ID = 10428, 'Merchant Service Commission', C.Name) --NG20210426
                    ELSE
                        ''
                END AS ProductSubCategory,
                m.Price,
                m.DiscAmount,
                m.Fee, --MR20240215
                (m.Price - m.DiscAmount + m.Fee) AS RetailCost, --MR20240215
                m.Account_ID,
                m.DateOrdered,
                CONVERT(VARCHAR(20), m.[MaCommissionAmount]) AS [MaCommissionAmount],
                m.DateDue AS DirectParentCommissionDateDue, --KMH20230831
                m.[MaInvoiceNumber],
                m.[Product SKU],                            --KMH20230831
                m.Company,                                  --KMH20230831
                m.UserID,                                   --KMH20230831
                m.Username,
                m.[MA],
                m.MA_AccountName,
                m.UniqueID
            FROM MyCte AS m
            LEFT JOIN dbo.Product_Category AS PC WITH (READUNCOMMITTED)
                ON m.Product_ID = PC.Product_ID
            LEFT JOIN dbo.Categories AS C WITH (READUNCOMMITTED)
                ON PC.Category_ID = C.Category_ID
            LEFT JOIN dbo.Categories AS C2 WITH (READUNCOMMITTED)
                ON C2.Category_ID = C.Parent_ID; --NG20210426

        END;

--DROP TABLE IF EXISTS #ListOfAccounts;
--DROP TABLE IF EXISTS #ListOfOrders0;
--DROP TABLE IF EXISTS #DistinctOrders0;
--DROP TABLE IF EXISTS #PrePAK;
--DROP TABLE IF EXISTS #PAK;
--DROP TABLE IF EXISTS #PreOrderAuth;
--DROP TABLE IF EXISTS #OrderAuth;
--DROP TABLE IF EXISTS #OiA;
--DROP TABLE IF EXISTS #OIAAuth;
--DROP TABLE IF EXISTS #ListOfCommInfo0;
--DROP TABLE IF EXISTS #ProductCategory0;
--DROP TABLE IF EXISTS #MAXtspTransactionFeed;
--DROP TABLE IF EXISTS #tspTransactionFeed;
--DROP TABLE IF EXISTS #ListOfOrders1;
--DROP TABLE IF EXISTS #ListOfCommInfo1;
--DROP TABLE IF EXISTS #ProductCategory1;

END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
