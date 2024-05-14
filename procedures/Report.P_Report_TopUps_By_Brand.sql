--liquibase formatted sql

--changeset Nicolas Griesdorn bfa9aa6d stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-05-09
				:
	Description	: SP used in CRM to report on Top-Ups by Brand
				:
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_TopUps_By_Brand]
    (
        @SessionID INT
        , @Carrier INT --Simple 4 TBV Non-FWA 292, TBV FWA 404 VZW 7, Tracfone 31, GenMobile 270, Ultra Mobile 8, Cricket Wireless 56, AT&T 26, Xfinity 276, H2O Wireless 2, H2O Bolt 17, FWA 404, MobileX 302 -- noqa: LT05
        , @StartDate DATE
        , @EndDate DATE
    )
AS
BEGIN TRY
    -----------------------------------------------------------------------------------------------------------------

    IF @Carrier NOT IN (276, 404) --All Other Brands except TBV FWA And Xfinity
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate)
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate)

            DROP TABLE IF EXISTS #AllOtherBrand

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [OrderSKU]
                , af1.AddonTypeName
                , CASE
                    WHEN LEN(oia.AddonsValue) > 4 THEN oia.AddonsValue
                    WHEN LEN(oia.AddonsValue) <= 4 THEN '******' + oia.AddonsValue
                END AS [AddonsValue]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #AllOtherBrand
            FROM dbo.Orders AS o
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN
                dbo.tblOrderItemAddons AS oia
                    LEFT JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('PhoneNumberType', 'BillItemNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = @Carrier
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (1, 9)
                AND o.Name NOT LIKE '%Total by Verizon Home Internet RTR%'
                AND onu.Process = 1
                AND onu.Filled = 1
                AND onu.Void = 0
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate



            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.[BillItemNumberType] AS [BillItemNumber]
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[OrderSKU]
                , pv.[PhoneNumberType] AS [Phone Number]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [OrderSKU]
                        , AddonsValue AS [Phone Number]
                        , AddonTypeName
                        , [Activation Platform]
                    FROM #AllOtherBrand
                ) AS APivotTable
            PIVOT
            (
                MAX([Phone Number])
                FOR AddonTypeName IN ([PhoneNumberType], [BillItemNumberType])
            ) pv;


            DROP TABLE IF EXISTS #AllOtherBrand
        END;


    -----------------------------------------------------------------------------------------------------------------------

    IF @Carrier = 404 --TBV FWA (404 does not exist, it was put here as a placeholder for TBV FWA since that falls under normal TBV)
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate)
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate)


            DROP TABLE IF EXISTS #TBVFWA

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [OrderSKU]
                , af1.AddonTypeName
                , CASE
                    WHEN LEN(oia.AddonsValue) > 4 THEN oia.AddonsValue
                    WHEN LEN(oia.AddonsValue) <= 4 THEN '******' + oia.AddonsValue
                END AS [AddonsValue]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #TBVFWA
            FROM dbo.Orders AS o
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN
                dbo.tblOrderItemAddons AS oia
                    LEFT JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('PhoneNumberType', 'BillItemNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = 292
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (1, 9)
                AND o.Name LIKE '%Total by Verizon Home Internet RTR%'
                AND onu.Process = 1
                AND onu.Filled = 1
                AND onu.Void = 0
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate

            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.[BillItemNumberType] AS [BillItemNumber]
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[OrderSKU]
                , pv.[PhoneNumberType] AS [Phone Number]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [OrderSKU]
                        , AddonsValue AS [Phone Number]
                        , AddonTypeName
                        , [Activation Platform]
                    FROM #TBVFWA
                ) AS APivotTable
            PIVOT
            (
                MAX([Phone Number])
                FOR AddonTypeName IN ([PhoneNumberType], [BillItemNumberType])
            ) pv;


            DROP TABLE IF EXISTS #TBVFWA
        END;


    -----------------------------------------------------------------------------------------------------------------------------

    IF @Carrier = 276 -- Xfinity Only 276
        BEGIN

            SET @StartDate = IIF(LEN(ISNULL(@StartDate, '')) = 0, DATEADD(DAY, -1, GETDATE()), @StartDate)
            SET @EndDate = IIF(LEN(ISNULL(@EndDate, '')) = 0, GETDATE(), @EndDate)

            DROP TABLE IF EXISTS #XfinityBrand

            SELECT
                a.ParentAccount_Account_ID AS [Top Parent]
                , onu.Account_ID
                , a.Account_Name
                , onu.Order_No
                , onu.DateOrdered
                , o.Product_ID
                , o.Name
                , o.SKU AS [OrderSKU]
                , af1.AddonTypeName
                , CASE
                    WHEN LEN(oia.AddonsValue) > 4 THEN oia.AddonsValue
                    WHEN LEN(oia.AddonsValue) <= 4 THEN '******' + oia.AddonsValue
                END AS [AddonsValue]
                , CASE
                    WHEN ONu.User_IPAddress LIKE '%DAPI:%' THEN 'DAP'
                    WHEN ONu.User_IPAddress LIKE '%prtl:%' THEN 'VIDAPAY'
                    WHEN ONu.User_IPAddress NOT LIKE '%DAPI:%' THEN 'VIDAPAY Classic'
                END AS [Activation Platform]
            INTO #XfinityBrand
            FROM dbo.Orders AS o
            JOIN
                dbo.tblOrderItemAddons AS oia
                    LEFT JOIN dbo.tblAddonFamily AS af1
                        ON
                            af1.AddonID = oia.AddonsID
                            AND af1.AddonTypeName IN ('PhoneNumberType')
                ON oia.OrderID = o.ID
            JOIN dbo.Order_No AS onu ON onu.Order_No = o.Order_No
            JOIN dbo.Account AS a ON a.Account_ID = onu.Account_ID
            JOIN dbo.Products AS p ON p.Product_ID = o.Product_ID
            JOIN Products.tblProductCarrierMapping AS pcm ON pcm.ProductId = p.Product_ID AND pcm.CarrierId = @Carrier
            WHERE
                ISNULL(O.ParentItemID, 0) IN (0, 1)
                AND onu.OrderType_ID IN (1, 9)
                AND onu.Process = 1
                AND onu.Filled = 1
                AND onu.Void = 0
                AND onu.DateOrdered BETWEEN @StartDate AND @EndDate



            SELECT
                pv.[Top Parent]
                , pv.Account_ID
                , pv.Account_Name
                , pv.Order_No
                , pv.DateOrdered
                , pv.[Plan Product ID]
                , pv.[Product Plan Name]
                , pv.[OrderSKU]
                , pv.[PhoneNumberType] AS [Phone Number]
                , pv.[Activation Platform]
            FROM
                (
                    SELECT
                        [Top Parent]
                        , Account_ID
                        , Account_Name
                        , Order_No
                        , DateOrdered
                        , Product_ID AS [Plan Product ID]
                        , Name AS [Product Plan Name]
                        , [OrderSKU]
                        , AddonsValue AS [Phone Number]
                        , AddonTypeName
                        , [Activation Platform]
                    FROM #XfinityBrand
                ) AS APivotTable
            PIVOT
            (
                MAX([Phone Number])
                FOR AddonTypeName IN ([PhoneNumberType], [BillItemNumberType])
            ) pv;


            DROP TABLE IF EXISTS #XfinityBrand
        END;


END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
