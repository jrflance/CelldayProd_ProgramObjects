--liquibase formatted sql

--changeset MHoward:0D5554 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
-- ==============================================================================
--             : 
--      Author : Brandon Stahl
--             : 
--     Created : 2018-12-19
--             : 
-- Description : This Sproc reconciles H2O confirmations and compares them against 
--             : T-Cetra orders to preemptively catch bill discrepancies.  
--             :
--  BS20190123 : Added Activation Product Mapping.
--             :
--  BS20190325 : Updated to work with the updated version of the confirmation 
--			   : report provided by Locus and fixed duplication issue.
--			   :
--  JL20190402 : Removed Test Code
--			   :
--  JL20190415 : Remove return at end of column 9
--			   :
-- 	MR20200204 : Updated the Chr1 to be date
--			   :
--  MR20200317 : Added VendorDiscrepancy insert logic for recon
--			   :
--	MR20200319 : Fixed the columns for the date to be all in column A
--			   :
--	MH20210301 : Added Cost check
--			   :
--       Usage : EXEC [Report].[P_Report_Accounting_LocusRTRConfirmationRecon]
--             :
--  MH20210922 : Updated Discrepancy insert to use NetCharges - Tcetra cost for Discrepancy Amount
--			   :	for Billed Incorrect Amount
--			   :
--  MH20240215 : Removed ParentItemID filter for excluding spiffs to accomidate activation fee
--  MH20240215 : Updated to new mapping logic
-- ================================================================================
-- noqa: enable=all
CREATE OR ALTER PROCEDURE [Report].[P_Report_Accounting_LocusRTRConfirmationRecon]
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    BEGIN TRY

        DECLARE
            @Delimeter VARCHAR(1) = '|',
            @TimeZoneAdj INT = -1,
            @DateMargin INT = 2;

        IF OBJECT_ID('tempdb..#Upload') IS NOT NULL
            BEGIN
                DROP TABLE #Upload;
            END;

        SELECT
            CAST(a.Chr1 AS DATETIME) AS [DATE], --BS20180325
            a.Chr2 AS Phone,
            a.Chr3 AS OrderNo,
            a.Chr4 AS UserName,
            CAST(a.Chr5 AS DECIMAL(9, 2)) AS ProductValue,
            CAST(a.Chr6 AS DECIMAL(9, 2)) AS DiscountRate,
            CAST(a.Chr7 AS DECIMAL(9, 2)) AS NetPayable,
            CAST(REPLACE(REPLACE(a.Chr8, CHAR(13), ''), CHAR(10), '') AS DECIMAL(9, 2)) AS Earned,
            a.Chr9 AS AccountantName
        INTO #Upload
        FROM CellDayTemp.[Recon].[tblPlainText] AS t
        CROSS APPLY dbo.SplitText(t.PlainText, @Delimeter, '"') AS a
        WHERE a.Chr1 <> 'DATE';

        --IF OBJECT_ID('tempdb..#DateFreq') IS NOT NULL
        --BEGIN
        --    DROP TABLE #DateFreq;
        --END;

        --SELECT CAST(u.[DATE] AS [DATE]) AS [Date],
        --       COUNT(1) AS Freq
        --INTO #DateFreq
        --FROM #Upload AS u
        --GROUP BY CAST(u.[DATE] AS DATE);

        IF OBJECT_ID('tempdb..#TC_Orders') IS NOT NULL
            BEGIN
                DROP TABLE #TC_Orders;
            END;

        SELECT
            ROW_NUMBER() OVER (
                PARTITION BY u.OrderNo
                ORDER BY ABS(DATEDIFF(SECOND, n.DateFilled, DATEADD(HOUR, @TimeZoneAdj, [u].[DATE])))
            ) AS rnum,
            u.DATE,
            n.Order_No,
            n.DateFilled,
            n.Filled,
            n.Process,
            o.Price,
            CASE																 --MH20210302
                WHEN dcp.Percent_Amount_Flg = 'P'
                    THEN o.Price - (o.Price * (dcp.Discount_Amt / 100))
                WHEN dcp.Percent_Amount_Flg = 'A'
                    THEN o.Price - dcp.Discount_Amt
            END AS TCetraAmtDue,
            o.DiscAmount,
            o.Name AS ProductName,
            o.Product_ID,
            o.SKU,
            o.ID,
            p.Product_Type,
            u.OrderNo,
            u.Phone,
            n.OrderType_ID				--MH20240215
        INTO #TC_ORDERS
        FROM dbo.Order_No AS n
        JOIN dbo.Orders AS o
            ON n.Order_No = o.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = o.Product_ID AND p.Product_Type IN (1, 3)				--MH20240215
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.OrderID = o.ID
        JOIN dbo.tblAddonFamily AS af
            ON oia.AddonsID = oia.AddonsID
        JOIN Products.tblProductCarrierMapping AS pcm
            ON pcm.ProductId = o.Product_ID
        JOIN dbo.Carrier_ID AS ci
            ON ci.ID = pcm.CarrierId
        JOIN dbo.DiscountClass_Products AS dcp						--MH20210302
            ON o.Product_ID = dcp.Product_ID AND dcp.DiscountClass_ID = 10
        JOIN #Upload AS u
            ON u.Phone = oia.AddonsValue
        WHERE
            n.DateFilled >= DATEADD(DAY, -1 * @DateMargin, u.DATE)
            AND n.DateFilled < DATEADD(DAY, @DateMargin, u.DATE)
            AND n.OrderType_ID IN (1, 9, 22, 23)
            AND n.Void = 0
            AND ci.ParentCompanyId = 3
            AND af.AddonTypeName =
            CASE
                WHEN
                    EXISTS
                    (
                        SELECT 1
                        FROM CellDay_Prod.dbo.tblOrderItemAddons AS oia
                        JOIN CellDay_Prod.dbo.tblAddonFamily AS af
                            ON oia.AddonsID = af.AddonID
                        WHERE af.AddonTypeName = 'PortInType' AND oia.OrderID = o.ID
                    )
                    THEN 'PhoneNumberType'
                ELSE 'ReturnPhoneType'
            END
        --AND ISNULL(o.ParentItemID, 0) = 0;			--MH20240215 (removed)

        --MH20240215, removed for new mapping logic below
        --IF OBJECT_ID('tempdb..#logData') IS NOT NULL
        --BEGIN
        --    DROP TABLE #logData;
        --END;
        ----BS20190123
        --SELECT ot.Order_No,
        --       ot.Product_ID,
        --       MIN(lvpm.ID) AS [MinLogId]
        --INTO #logData
        --FROM #TC_ORDERS ot
        --    JOIN [Logs].[VendorProductMapping] lvpm
        --        ON CAST(lvpm.ProductIdBefore AS VARCHAR(10)) = ot.Product_ID
        --           AND ot.DateFilled < lvpm.LogDate
        --           AND NOT EXISTS
        --                   (
        --                       SELECT 1
        --                       FROM dbo.Order_Activation_User_Lock oaul
        --                       WHERE oaul.Order_No = ot.Order_No
        --                   )
        --           AND lvpm.RegiondIdBefore = CASE
        --                                          WHEN EXISTS
        --                                               (
        --                                                   SELECT 1
        --                                                   FROM dbo.tblOrderItemAddons oia
        --                                                   WHERE oia.OrderID = ot.ID
        --                                                         AND oia.AddonsID = 26
        --                                               )
        --                                               AND EXISTS
        --                                                   (
        --                                                       SELECT 1
        --                                                       FROM [Logs].[VendorProductMapping] lvpm2
        --                                                       WHERE lvpm2.RegiondIdBefore = 4
        --                                                             AND ot.DateFilled < lvpm2.LogDate
        --                                                             AND lvpm2.VendorSkuBefore IS NOT NULL
        --                                                             AND CAST(lvpm2.ProductIdBefore AS VARCHAR(10)) = ot.Product_ID
        --                                                   ) THEN
        --                                              4
        --                                          ELSE
        --                                              1
        --                                      END
        --GROUP BY ot.Order_No,
        --         ot.Product_ID;

        ----BS20190123
        --IF OBJECT_ID('tempdb..#VendorData') IS NOT NULL
        --BEGIN
        --    DROP TABLE #VendorData;
        --END;

        --SELECT DISTINCT
        --       ot.Order_No,
        --       ot.Product_ID,
        --       vpm.Region_ID,
        --       CASE
        --           WHEN EXISTS
        --                (
        --                    SELECT 1
        --                    FROM dbo.Order_Activation_User_Lock oaul
        --                    WHERE oaul.Order_No = ot.Order_No
        --                ) THEN
        --               ISNULL(p.Vendor1_SKU, ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID))
        --           ELSE
        --               ISNULL(CAST(vpm.Vendor_SKU AS VARCHAR(10)), ot.Product_ID)
        --       END AS [VendorSku],
        --       vpm.Vendor_SKU AS vpmVendor_SKU
        --INTO #VendorData
        --FROM #TC_ORDERS ot
        --    JOIN dbo.Products AS p
        --        ON p.Product_ID = ot.Product_ID
        --    JOIN dbo.Vendor_Product_Mapping vpm
        --        ON CAST(vpm.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --           AND vpm.Region_ID = CASE
        --                                   WHEN EXISTS
        --                                        (
        --                                            SELECT 1
        --                                            FROM dbo.tblOrderItemAddons oia
        --                                            WHERE oia.OrderID = ot.ID
        --                                                  AND oia.AddonsID = 26
        --                                        )
        --                                        AND EXISTS
        --                                            (
        --                                                SELECT 1
        --                                                FROM dbo.Vendor_Product_Mapping vpm2
        --                                                WHERE vpm2.Region_ID = 4
        --                                                      AND vpm2.Vendor_SKU IS NOT NULL
        --                                                      AND CAST(vpm2.Product_ID AS VARCHAR(10)) = ot.Product_ID
        --                                            ) THEN
        --                                       4
        --                                   ELSE
        --                                       1
        --                               END;





        IF OBJECT_ID('tempdb..#Duplicates') IS NOT NULL
            BEGIN
                DROP TABLE #Duplicates;
            END;

        SELECT
            t.Order_No,
            COUNT(1) AS [Count] -- noqa: CV04
        INTO #Duplicates
        FROM #TC_ORDERS AS t
        WHERE t.rnum = 1
        GROUP BY t.Order_No, t.Phone
        HAVING COUNT(1) > 1; -- noqa: CV04

        IF OBJECT_ID('tempdb..#Results') IS NOT NULL
            BEGIN
                DROP TABLE #Results;
            END;

        SELECT
            CAST(u.[DATE] AS DATE) AS [Date],
            u.OrderNo, --BS20180325
            u.UserName,
            u.ProductValue,
            u.DiscountRate,
            u.NetPayable,
            u.Earned,
            t.Order_No,
            t.DateFilled,
            t.Price,
            t.TCetraAmtDue,				--MH20210302
            t.DiscAmount,
            t.ProductName,
            --CASE --BS20190123			--MH20240215 (removed)
            --    WHEN ISNULL(t.Product_Type, 0) = 3 THEN
            --        ISNULL(
            --                  ISNULL(CAST(tvpm.VendorSkuBefore AS VARCHAR(10)), CAST(vd.VendorSku AS VARCHAR(10))),
            --                  t.Product_ID
            --              )
            --    ELSE
            --        t.Product_ID
            --END AS Product_ID,
            p.Product_ID,
            t.SKU,
            CASE
                WHEN t.Order_No IS NULL
                    THEN 'Missing'
                WHEN EXISTS (SELECT 1 FROM #Duplicates AS d WHERE d.Order_No = t.Order_No)
                    THEN 'Duplicate'
                WHEN t.Filled = 0
                    THEN 'Pending'
                WHEN t.TCetraAmtDue <> u.NetPayable
                    THEN 'Billed Incorrect Amt'
                ELSE 'Success'				--MR20190711
            END AS Status,
            u.AccountantName
        INTO #Results
        FROM #Upload AS u
        LEFT JOIN #TC_ORDERS AS t
            ON u.OrderNo = t.OrderNo AND t.rnum = 1
        LEFT JOIN dbo.Products AS p2					--MH20240215
            ON t.Product_ID = p2.Product_ID
        LEFT JOIN Orders.tblOrderVendorDetails AS vd
            ON t.ID = vd.OrderId AND t.OrderType_ID IN (22, 23)
        LEFT JOIN dbo.Vendor_Product_Mapping AS vpm
            ON t.Product_ID = vpm.Product_ID AND vpm.Region_ID = 1 AND t.OrderType_ID IN (22, 23)
        LEFT JOIN dbo.Products AS p
            ON
                CASE
                    WHEN t.OrderType_ID IN (22, 23) AND p2.Product_Type = 3
                        THEN ISNULL(ISNULL(vd.FundingProductID, vpm.Vendor_SKU), t.Product_ID)
                    ELSE t.Product_ID
                END = p.Product_ID
                --LEFT JOIN #logData l				--MH20240215 (removed)
                --    ON l.Order_No = t.Order_No
                --LEFT JOIN #VendorData AS vd
                --    ON vd.Order_No = t.Order_No
                --       AND t.Product_ID = vd.Product_ID --BS20180325
                --LEFT JOIN [Logs].[VendorProductMapping] tvpm
                --    ON tvpm.ID = l.[MinLogId];

        TRUNCATE TABLE CellDayTemp.Recon.tblLocusRTRConfirmationResult;
        INSERT INTO CellDayTemp.Recon.tblLocusRTRConfirmationResult
        (
            [DATE],
            OrderNo,
            UserName, --BS20180325
            ProductValue,
            DiscountRate,
            NetPayable,
            TCetraAmtDue,				--MH20210302
            Earned,
            Order_No,
            DateFilled,
            Price,
            DiscAmount,
            ProductName,
            Product_ID,
            SKU,
            [Status]
        )
        SELECT
            [DATE],
            OrderNo,
            UserName,
            ProductValue,
            DiscountRate,
            NetPayable,
            TCetraAmtDue,
            Earned,
            Order_No,
            DateFilled,
            Price,
            DiscAmount,
            ProductName,
            Product_ID,
            SKU,
            [STATUS]
        FROM #Results

        INSERT INTO Cellday_Accounting.acct.VendorInvoice				--MR20190711
        (
            InvoiceNo,
            InvoiceDate,
            Process_Id
        )

        SELECT DISTINCT
            concat(YEAR(r.Date), MONTH(r.Date), DAY(r.Date), 'LOCUS') AS InvoiceNo,
            r.[Date] AS InvoiceDate,
            5 AS Process_ID -- Locus
        FROM #Results AS r



        INSERT INTO Cellday_Accounting.acct.VendorDiscrepancies			--MR20190711
        (
            Process_Id,
            DateCreated,
            UserCreated,
            Discrepancy_ID,
            DiscrepancyAmt,
            TransactionID,
            Order_No,
            VendorInvoice_ID
        )
        SELECT
            5 AS process_ID,			--Locus
            GETDATE() AS DateCreated,
            r.AccountantName AS UserCreated,
            CASE
                WHEN r.Status = 'Missing' THEN 14
                WHEN r.status = 'Pending' THEN 10
                WHEN r.Status = 'Billed Incorrect Amt' THEN 15				--MH20210302
                WHEN r.status = 'Duplicate' THEN 16
                ELSE 11
            END AS Discrepancy_ID,
            --(r.Price - r.DiscAmount) AS DiscrepancyAmt,					--MH20210922
            CASE
                WHEN r.Status = 'Billed Incorrect Amt'
                    THEN r.NetPayable - r.TCetraAmtDue
                ELSE r.NetPayable
            END AS DiscrepancyAmt,
            r.sku AS TransactionID,
            r.OrderNo AS Order_NO,
            vi.ID AS VendorInvoice_ID
        FROM #Results AS r
        JOIN Cellday_Accounting.acct.VendorInvoice AS vi
            ON vi.InvoiceDate = r.Date AND vi.Process_Id = 5	 --Locus
        WHERE r.Status <> 'Success'

    END TRY
    BEGIN CATCH
    ; THROW;
    END CATCH;
END
-- noqa: disable=all
/

